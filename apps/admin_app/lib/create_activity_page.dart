/// 新建活动（管理端）。
///
/// ## 这个页面为什么重要
/// 方案 §4.1 的活动字段里，**签到坐标是判定的基准**：签到能否通过，
/// 取决于志愿者与这个坐标的距离。而此前管理端**没有录入界面**，
/// 只能依赖种子数据 —— 于是"想测签到就得跑到图书馆去"。
///
/// 这个页面的核心不是表单本身，而是顶部那个
/// **「用当前位置作为签到点」** 按钮：一键把手机当前位置填进去，
/// 于是在任何地方都能造出一个"站在旁边就能签上"的活动，
/// 真机验证才做得下去。
///
/// ## 与契约的对应
///
/// * 走 `POST /activities:upsert`（动作后缀，不是 `POST /activities`）；
/// * `externalId` 是**必填**的幂等键，同一值重复上报视为更新（§5.4）。
///   这里自动生成，用户不必理解它是什么；
/// * 校验用 `ActivityValidator.validate()` —— 与服务端同源的规则，
///   避免"前端放过、服务端拒绝"的来回。
///
/// ## 一个刻意的取舍：不内置地图选点
///
/// 方案里提到"地图选点"，但引入地图 SDK 需要密钥与网络权限，
/// 对一个校内工具是过重的依赖。因此提供三条更轻的路径：
///   1. 用手机当前位置（最常用，也是真机验证需要的）；
///   2. 手工填经纬度（从别处复制，例如地图 App 长按复制坐标）；
///   3. 只填文字地点、不填坐标（活动可见，但不能签到判定）。
///
/// 第 3 条要明确告知后果，否则发布者会以为"填了地点就能签到"。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:shared_core/shared_core.dart';
import 'package:shared_platform/shared_platform.dart';
import 'package:shared_ui/shared_ui.dart';

class CreateActivityPage extends StatefulWidget {
  const CreateActivityPage({super.key});

  @override
  State<CreateActivityPage> createState() => _CreateActivityPageState();
}

class _CreateActivityPageState extends State<CreateActivityPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  // ── 输入控制器 ──────────────────────────────────────────────────────
  late final TextEditingController _title;
  late final TextEditingController _organizer;
  late final TextEditingController _location;
  late final TextEditingController _lat;
  late final TextEditingController _lng;
  late final TextEditingController _radius;
  late final TextEditingController _summary;
  late final TextEditingController _description;
  late final TextEditingController _contact;
  late final TextEditingController _quota;
  late final TextEditingController _duration;

  // ── 时间 ────────────────────────────────────────────────────────────
  DateTime _start = DateTime.now();
  DateTime _end = DateTime.now().add(const Duration(hours: 2));

  // ── 状态 ────────────────────────────────────────────────────────────
  String _locationType = 'outdoor';
  bool _publishNow = true;
  bool _locating = false;
  bool _submitting = false;

  /// 在岗抽查方式（自动/手动）。默认自动，与老行为一致。
  AttendanceMode _attendanceMode = AttendanceMode.auto;
  String? _error;
  /// 字段级错误（来自本地校验或服务端返回），键是字段名。
  Map<String, String> _fieldErrors = <String, String>{};

  /// 定位辅助信息（取得位置后显示精度，让人知道这次定位靠不靠谱）。
  String? _locateHint;

  // ── 场地网络（提升自动通过率的关键）─────────────────────────────────
  //
  // 评分表里围栏 40 + 采样一致 10 = 50，自动通过门槛 60。
  // 差的 10–30 分**只能**来自网络辅证：Wi-Fi BSSID +20 / 校园网 IP +10。
  // 而服务端只在活动配了白名单时才计分。所以这两项空着，
  // 志愿者每次签到都会转人工确认 —— 现场发布者要逐条点。
  List<String> _wifiBssids = <String>[];
  List<String> _ipPrefixes = <String>[];
  bool _capturingNetwork = false;
  String? _networkNote;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _start = DateTime(now.year, now.month, now.day, now.hour, now.minute);
    _end = _start.add(const Duration(hours: 2));

    _title = TextEditingController();
    _organizer = TextEditingController(text: '校青年志愿者协会');
    _location = TextEditingController();
    _lat = TextEditingController();
    _lng = TextEditingController();
    _radius = TextEditingController(text: '300');
    _summary = TextEditingController();
    _description = TextEditingController();
    _contact = TextEditingController();
    _quota = TextEditingController(text: '20');
    _duration = TextEditingController(text: '2');
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _title, _organizer, _location, _lat, _lng, _radius,
      _summary, _description, _contact, _quota, _duration,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════
  // 定位
  // ═══════════════════════════════════════════════════════════════════

  /// 一键用当前位置作为签到点。
  ///
  /// 这是本页最重要的操作：它把"造一个能签到的活动"从
  /// "查经纬度、手工敲数字"变成一次点击。
  /// 用**发布者当前所在的网络**填场地白名单。
  ///
  /// ## 为什么不能让人手工填 BSSID
  ///
  /// BSSID 形如 `a4:2b:8c:11:22:33`，发布者在现场根本抄不出来；
  /// 校园网前缀也要先知道自己的 IP 才写得出。
  /// 让他"站在场地里点一下"是唯一可行的交互。
  ///
  /// ## 为什么两项都取
  ///
  /// 两项是**独立的加分来源**（Wi-Fi +20、校园网 +10）。
  /// 只配一项也够过 60 分门槛（40+10+10=60），但两项都配更稳：
  /// 有的场地没有独立 AP，有的校园网跨多个 /16。
  Future<void> _captureCurrentNetwork() async {
    final AppServices services = AppScope.of(context);
    setState(() {
      _capturingNetwork = true;
      _networkNote = null;
    });

    try {
      final String? bssid = await services.connectivity.wifiBssid();
      final String? ip = await services.connectivity.localIp();
      if (!mounted) {
        return;
      }

      final List<String> bssids = <String>[];
      final List<String> prefixes = <String>[];
      if (bssid != null) {
        bssids.add(bssid);
      }
      if (ip != null) {
        // 取前两段作网段前缀（如 `10.3.`、`202.119.`）。
        //
        // 为什么是两段而不是三段：校园网通常一个 /16 内会分很多 /24，
        // 只取 /24 的话换个楼就命中不了；两段是"同一所学校"的合理粒度。
        // 太宽会误判（把校外的 10.x 也算进来），所以不再放宽到一段。
        final List<String> parts = ip.split('.');
        if (parts.length == 4) {
          prefixes.add('${parts[0]}.${parts[1]}.');
        }
      }

      setState(() {
        _capturingNetwork = false;
        if (bssids.isNotEmpty) {
          _wifiBssids = bssids;
        }
        if (prefixes.isNotEmpty) {
          _ipPrefixes = prefixes;
        }
        if (bssids.isEmpty && prefixes.isEmpty) {
          _networkNote = '没读到网络信息。请确认已连上 Wi-Fi，'
              '并允许定位权限（Android 读 Wi-Fi 名称需要它）。'
              '也可以跳过：不配网络时志愿者需人工确认。';
        } else if (bssids.isEmpty) {
          _networkNote = '只读到校园网网段（没读到 Wi-Fi 名称）。'
              '只配网段也能加分，够过自动通过门槛。';
        } else if (prefixes.isEmpty) {
          _networkNote = '只读到 Wi-Fi 名称（没读到本机 IP）。'
              '只配 Wi-Fi 也能加分，够过自动通过门槛。';
        } else {
          _networkNote = null;
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _capturingNetwork = false;
        _networkNote = '读取网络信息失败。可以跳过这一项，不影响发布活动。';
      });
    }
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _locating = true;
      _locateHint = null;
      _error = null;
    });

    final AppServices services = AppScope.of(context);
    try {
      final LocationPermissionState perm = await services.location.ensurePermission();
      if (perm == LocationPermissionState.deniedForever ||
          perm == LocationPermissionState.denied) {
        if (!mounted) {
          return;
        }
        setState(() {
          _locating = false;
          _error = '没有定位权限。你可以到系统设置里打开，或手工填经纬度。';
        });
        return;
      }

      final PositionFix fix = await services.location.getCurrentFix();
      if (!mounted) {
        return;
      }

      setState(() {
        _locating = false;
        _lat.text = fix.point.lat.toStringAsFixed(6);
        _lng.text = fix.point.lng.toStringAsFixed(6);
        // 精度是判断"这个点能不能用"的唯一依据：室内常常上百米，
        // 那种精度做签到点会让判定失去意义，必须让人看见。
        _locateHint = '已取得当前位置，精度约 ±${fix.accuracy.round()} 米'
            '${fix.accuracy > 100 ? '（精度较差，建议到室外再取一次）' : ''}';
        _fieldErrors = <String, String>{};
      });

      // 地点文字留空时，用坐标补一个可读的默认值 ——
      // 空白的地点会让列表项看起来像数据缺失。
      if (_location.text.trim().isEmpty) {
        _location.text = '当前位置附近';
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _locating = false;
        _error = e is LocationException
            ? e.userMessage
            : '获取位置失败，请重试或手工填写经纬度。';
      });
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // 提交
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _fieldErrors = <String, String>{};
      _submitting = true;
    });

    final AppServices services = AppScope.of(context);

    // 1) 本地校验（与服务端同源规则）。
    final ActivityFormInput input = ActivityFormInput(
      title: _title.text,
      organizer: _organizer.text,
      startTimeText: _fmt(_start),
      endTimeText: _fmt(_end),
      durationHoursText: _duration.text,
      location: _location.text,
      geoLatText: _lat.text,
      geoLngText: _lng.text,
      checkinRadiusText: _radius.text,
      summary: _summary.text,
      description: _description.text,
      contact: _contact.text,
      quotaText: _quota.text,
    );

    final ValidationResult validation = ActivityValidator.validate(
      input,
      now: DateTime.now(),
    );
    if (validation.errors.isNotEmpty) {
      setState(() {
        _submitting = false;
        _fieldErrors = <String, String>{
          for (final FieldError e in validation.errors) e.field: e.message,
        };
        // 把第一条错误也提到顶部，避免错误在屏幕外（长表单常见）。
        _error = validation.errors.first.message;
      });
      return;
    }

    // 2) 生成 externalId。
    //
    // 契约要求必填且 ≤64 字符，且**同值视为更新**。这里用时间戳生成，
    // 确保每次新建都是新记录；对发布者隐藏这个内部概念。
    final String externalId = _newExternalId();

    final Map<String, Object?> payload = <String, Object?>{
      'externalId': externalId,
      'title': _title.text.trim(),
      'organizer': _organizer.text.trim(),
      'location': _location.text.trim(),
      'locationType': _locationType,
      'durationHours': double.tryParse(_duration.text.trim()) ?? 2,
      // 时间用 ISO 8601 含偏移（契约 §4.1）。`_iso` 保证不是 UTC 的 Z 形式，
      // 否则前端显示会差 8 小时。
      'startTime': _iso(_start),
      'endTime': _iso(_end),
      'summary': _summary.text.trim(),
      'description': _description.text.trim(),
      'contact': _contact.text.trim(),
      ...?(_lat.text.trim().isEmpty
          ? null
          : <String, Object?>{
              'geoLat': double.tryParse(_lat.text.trim()),
              'geoLng': double.tryParse(_lng.text.trim()),
            }),
      ...?(_radius.text.trim().isEmpty
          ? null
          : <String, Object?>{'checkinRadius': int.tryParse(_radius.text.trim())}),
      ...?(_quota.text.trim().isEmpty
          ? null
          : <String, Object?>{'quota': int.tryParse(_quota.text.trim())}),
      // 场地网络白名单：服务端只在**活动配了白名单**时才计入网络辅证分
      //（否则谁都能填个 BSSID 骗分）。空列表不下发，让服务端用"未配置"语义。
      if (_wifiBssids.isNotEmpty) 'wifiBssids': _wifiBssids,
      if (_ipPrefixes.isNotEmpty) 'campusIpPrefixes': _ipPrefixes,
      // 直接发布还是留作草稿。真机验证时通常希望立刻可见。
      // 抽查方式：自动按间隔生成，手动由发布者在看板上触发
      'attendanceMode': _attendanceMode.wire,
      'status': _publishNow ? 'published' : 'draft',
    };

    final ApiResult<Map<String, dynamic>> result =
        await services.api.post<Map<String, dynamic>>(
      ActivityPaths.upsert,
      // 契约支持 `{ batch: [...] }`；单条也接受，但用 batch 更贴近正式上报形态。
      body: <String, Object?>{'batch': <Object?>[payload]},
      idempotencyKey: services.api.newIdempotencyKey(),
      /*
        ⚠️ `decode` **必须给**，否则即使服务端返回 200 + code 0，
        客户端也会得到 `data == null`。

        原因在 `ApiResponse.fromJson`：

            data: rawData == null || fromData == null ? null : fromData(rawData),

        `fromData`（即 `decode`）为 null 时，data **恒为 null**，
        然后 ApiClient 会把"成功但没数据"当成失败：

            message: '服务端返回成功但缺少数据'

        这个坑真机测试才暴露出来：活动其实**已经创建成功**
        （服务端查得到），但界面报错并停在表单上，
        再点一次发布就会产生重复活动（externalId 每次新生成）。

        泛型 `T` 不能靠运行时反射自动解码 —— Dart 没有那样的能力，
        所以每个需要 data 的调用都必须显式传 decode。
      */
      decode: (Object? data) =>
          (data! as Map<Object?, Object?>).cast<String, dynamic>(),
    );

    if (!mounted) {
      return;
    }

    /*
      ⚠️ 这里必须同时处理**两种失败**，否则用户会以为"存成功了"。

      1. `ApiFailure`：整批失败（网络、鉴权、请求体被拒）。
      2. `rejected[]` 非空：**部分失败** —— 合法行入库、非法行逐条驳回。
         方案 §8 / 验收 A8 明确规定这种情况下 HTTP 仍是 200、code 仍是 0，
         只有 `rejected[]` 里能看出问题。若只看 `code === 0` 就当成功，
         用户会发现"提示成功了但活动没出现"。

      第 2 种是这套契约里最容易漏的分支。这里是单条上报，
      所以 rejected 一旦非空就等于整条失败 —— 直接当错误处理。
    */
    switch (result) {
      case ApiFailure<Map<String, dynamic>>(:final String message, :final List<FieldError> fieldErrors):
        setState(() {
          _submitting = false;
          _error = message.isEmpty ? '创建失败，请重试。' : message;
          // 服务端返回的字段错误直接标到对应输入框。
          if (fieldErrors.isNotEmpty) {
            _fieldErrors = <String, String>{
              for (final FieldError e in fieldErrors) e.field: e.message,
            };
          }
        });
        return;

      case ApiSuccess<Map<String, dynamic>>(:final Map<String, dynamic> value):
        final List<Object?> rejected =
            (value['rejected'] as List<Object?>?) ?? const <Object?>[];
        if (rejected.isNotEmpty) {
          final Object? first = rejected.first;
          final List<Object?> errs =
              (first is Map ? (first['errors'] as List<Object?>?) : null) ??
                  const <Object?>[];
          final List<String> messages = errs
              .whereType<Map<Object?, Object?>>()
              .map((Map<Object?, Object?> m) => '${m['message'] ?? ''}')
              .where((String s) => s.isNotEmpty)
              .toList();
          setState(() {
            _submitting = false;
            _error = messages.isEmpty
                ? '活动未能保存，请检查填写内容。'
                : '活动未能保存：${messages.join('；')}';
          });
          return;
        }

      // 4) 成功
    }

    if (!mounted) {
      return;
    }
    setState(() => _submitting = false);
    Navigator.of(context).pop(externalId);
  }

  /// 生成 externalId。
  ///
  /// 格式 `M-<yyMMdd>-<HHmmss>-<随机 3 位>`：
  /// 时间前缀让同一场活动在后台一眼能看出创建时间，
  /// 随机后缀避免同一秒内连点两次产生重复。
  String _newExternalId() {
    final DateTime n = DateTime.now();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    final int r = (n.millisecond * 7 + n.second) % 1000;
    return 'M-${p(n.year % 100)}${p(n.month)}${p(n.day)}-'
        '${p(n.hour)}${p(n.minute)}${p(n.second)}-${p(r, 3)}';
  }

  /// `yyyy-MM-dd HH:mm`（契约的展示格式）。
  String _fmt(DateTime d) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  /// ISO 8601 **含本地偏移**（不是 UTC 的 `Z`）。
  String _iso(DateTime d) {
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    final Duration off = d.timeZoneOffset;
    final String sign = off.isNegative ? '-' : '+';
    final int totalMin = off.inMinutes.abs();
    return '${d.year}-${p(d.month)}-${p(d.day)}'
        'T${p(d.hour)}:${p(d.minute)}:${p(d.second)}'
        '$sign${p(totalMin ~/ 60)}:${p(totalMin % 60)}';
  }

  // ═══════════════════════════════════════════════════════════════════
  // 时间选择
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _pickDateTime({required bool isStart}) async {
    final DateTime initial = isStart ? _start : _end;
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: isStart ? '选择开始日期' : '选择结束日期',
    );
    if (date == null || !mounted) {
      return;
    }
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: isStart ? '选择开始时间' : '选择结束时间',
    );
    if (time == null || !mounted) {
      return;
    }

    final DateTime picked = DateTime(
      date.year, date.month, date.day, time.hour, time.minute,
    );
    setState(() {
      if (isStart) {
        _start = picked;
        // 结束早于开始是常见误操作：自动把结束顺延到 2 小时后，
        // 而不是让用户去改一个报错的字段。
        if (!_end.isAfter(_start)) {
          _end = _start.add(const Duration(hours: 2));
        }
      } else {
        _end = picked;
      }
      // 时长跟着时间联动，避免"时间改了但时长没改"的不一致。
      final double hours =
          _end.difference(_start).inMinutes / 60.0;
      _duration.text = hours > 0 ? hours.toStringAsFixed(1) : '2';
      _fieldErrors = <String, String>{};
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  // 构建
  // ═══════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('新建活动'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '取消',
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md, Spacing.md, Spacing.md, Spacing.xxl,
          ),
          children: <Widget>[
            // ── 定位入口放最上 ────────────────────────────────────────
            //
            // 刻意的顺序：这是本页最高频的操作，也决定了后面能不能签到。
            // 放在长表单底部会让人填完才发现"没定位"。
            _LocationCard(
              locating: _locating,
              hint: _locateHint,
              lat: _lat.text,
              lng: _lng.text,
              onUseCurrent: _locating || _submitting ? null : _useCurrentLocation,
            ),

            if (_error != null) ...<Widget>[
              const SizedBox(height: Spacing.md),
              _ErrorBanner(message: _error!),
            ],

            const SizedBox(height: Spacing.lg),

            _Section(
              title: '基本信息',
              children: <Widget>[
                _field(
                  key: 'title',
                  controller: _title,
                  label: '活动名称',
                  hint: '例如：图书馆书架整理志愿服务',
                  required: true,
                  maxLength: 60,
                ),
                _field(
                  key: 'organizer',
                  controller: _organizer,
                  label: '组织部门',
                  hint: '例如：校青年志愿者协会',
                  required: true,
                  maxLength: 50,
                ),
                _field(
                  key: 'summary',
                  controller: _summary,
                  label: '一句话简介',
                  hint: '列表页会显示，说清做什么',
                  required: true,
                  maxLength: 120,
                  maxLines: 2,
                ),
              ],
            ),

            const SizedBox(height: Spacing.lg),

            _Section(
              title: '时间',
              children: <Widget>[
                _TimeRow(
                  label: '开始时间',
                  value: _fmt(_start),
                  onTap: _submitting ? null : () => _pickDateTime(isStart: true),
                ),
                _TimeRow(
                  label: '结束时间',
                  value: _fmt(_end),
                  onTap: _submitting ? null : () => _pickDateTime(isStart: false),
                ),
                _field(
                  key: 'durationHours',
                  controller: _duration,
                  label: '志愿时长（小时）',
                  hint: '与起止时间联动，也可手工调整',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  required: true,
                ),
              ],
            ),

            const SizedBox(height: Spacing.lg),

            _Section(
              title: '签到点',
              children: <Widget>[
                _field(
                  key: 'location',
                  controller: _location,
                  label: '活动地点',
                  hint: '例如：南湖校区图书馆三层',
                  required: true,
                  maxLength: 100,
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _field(
                        key: 'geoLat',
                        controller: _lat,
                        label: '纬度',
                        hint: '34.2175',
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true,
                        ),
                        mono: true,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: _field(
                        key: 'geoLng',
                        controller: _lng,
                        label: '经度',
                        hint: '117.1425',
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true,
                        ),
                        mono: true,
                      ),
                    ),
                  ],
                ),
                if (_lat.text.trim().isEmpty)
                  _Notice(
                    icon: Icons.info_outline,
                    /*
                      ⚠️ 文案与校验规则必须一致。

                      最初这里写的是"不填坐标也能用，只是签不上"，
                      但 `ActivityValidator` 实际把坐标列为**必填**
                      （`lat == null → 请在地图上选择活动位置`）。
                      于是界面在骗人：用户以为可以先跳过、之后再说，
                      提交时却被打回。

                      现在两处统一为「必填」，并把原因说清楚：
                      这不是表单洁癖 —— 没有坐标的活动，
                      志愿者能看到却永远签不上，比看不到更糟
                      （会让人以为定位功能坏了）。
                    */
                    text: '坐标是必填项：没有坐标的活动无法判断签到是否在范围内，'
                        '志愿者能看到却签不上。点上面的「用当前位置」最省事。',
                  ),
                _field(
                  key: 'checkinRadius',
                  controller: _radius,
                  label: '签到半径（米）',
                  hint: '室外 300，室内 150',
                  keyboardType: TextInputType.number,
                ),
                _LocationTypeRow(
                  value: _locationType,
                  onChanged: _submitting
                      ? null
                      : (String v) {
                          setState(() {
                            _locationType = v;
                            // 切换场地类型时顺带修正默认半径 ——
                            // 室内用 300 米会把范围放得过大，失去意义。
                            if (_radius.text.trim() == '300' ||
                                _radius.text.trim() == '150') {
                              _radius.text = v == 'indoor' ? '150' : '300';
                            }
                          });
                        },
                ),
              ],
            ),

            const SizedBox(height: Spacing.lg),

            /*
              ── 场地网络（决定"自动通过"能不能发生）─────────────────────

              这一块以前完全没有，后果是真机上**所有签到都转人工确认**：
              评分表里围栏 40 + 采样一致 10 = 50，而自动通过门槛是 60。
              差的 10–30 分只能来自网络辅证（Wi-Fi +20 / 校园网 +10），
              而服务端只在**活动配置了白名单**时才计分
              （"无法证明就不参与判定"——否则谁都能填个 BSSID 拿分）。

              也就是说：**发布者不配这两项，志愿者就永远要人工确认**。
              现场发布者得一条条点，这直接决定产品可用性。
              所以把"用当前网络"做成按钮：发布者站在场地里点一下就有。
            */
            _Section(
              title: '在岗抽查',
              children: <Widget>[
                _Notice(
                  icon: Icons.touch_app_outlined,
                  text: '在岗抽查是活动进行中随机要求志愿者「确认还在现场」。'
                      '自动抽查按间隔一直发（长活动合适）；'
                      '手动抽查只在你看板上点「手动抽查」时才发一次（短活动、临时点名叫）。',
                ),
                const SizedBox(height: Spacing.sm),
                SegmentedButton<AttendanceMode>(
                  segments: AttendanceMode.values
                      .map((AttendanceMode m) => ButtonSegment<AttendanceMode>(
                            value: m,
                            label: Text(m.label),
                            icon: Icon(
                              m == AttendanceMode.auto
                                  ? Icons.autorenew
                                  : Icons.touch_app_outlined,
                            ),
                          ))
                      .toList(),
                  selected: <AttendanceMode>{_attendanceMode},
                  onSelectionChanged: _submitting
                      ? null
                      : (Set<AttendanceMode> v) =>
                          setState(() => _attendanceMode = v.first),
                ),
                const SizedBox(height: Spacing.xxs),
                Text(
                  _attendanceMode.hint,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),

            const SizedBox(height: Spacing.lg),

            _Section(
              title: '场地网络（可选，但强烈建议配）',
              children: <Widget>[
                _Notice(
                  icon: Icons.wifi_tethering,
                  text: '配了这两项，志愿者连场地网络时能多拿 20 / 10 分，'
                      '才可能自动通过；不配的话每次签到都要人工确认。'
                      '点下面的按钮，用你当前所在的网络。',
                ),
                const SizedBox(height: Spacing.sm),
                AppButton(
                  label: _capturingNetwork ? '正在读取…' : '用当前网络作为场地网络',
                  icon: Icons.wifi_find,
                  variant: AppButtonVariant.secondary,
                  loading: _capturingNetwork,
                  loadingLabel: '正在读取网络…',
                  onPressed:
                      _submitting || _capturingNetwork ? null : _captureCurrentNetwork,
                ),
                if (_wifiBssids.isNotEmpty || _ipPrefixes.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Spacing.sm),
                  _NetworkSummary(
                    bssids: _wifiBssids,
                    ipPrefixes: _ipPrefixes,
                    onClear: _submitting
                        ? null
                        : () => setState(() {
                              _wifiBssids = <String>[];
                              _ipPrefixes = <String>[];
                              _networkNote = null;
                            }),
                  ),
                ],
                if (_networkNote != null) ...<Widget>[
                  const SizedBox(height: Spacing.xs),
                  _Notice(icon: Icons.info_outline, text: _networkNote!),
                ],
              ],
            ),

            const SizedBox(height: Spacing.lg),

            _Section(
              title: '其他（可选）',
              children: <Widget>[
                _field(
                  key: 'description',
                  controller: _description,
                  label: '活动说明',
                  hint: '工作内容、注意事项。空行分段。',
                  maxLines: 4,
                ),
                _field(
                  key: 'contact',
                  controller: _contact,
                  label: '联系方式',
                  hint: '手机号或称呼（公开页面会掩码手机号）',
                  maxLength: 50,
                ),
                _field(
                  key: 'quota',
                  controller: _quota,
                  label: '招募人数',
                  hint: '留空表示不限',
                  keyboardType: TextInputType.number,
                ),
              ],
            ),

            const SizedBox(height: Spacing.lg),

            SwitchListTile(
              value: _publishNow,
              onChanged: _submitting
                  ? null
                  : (bool v) => setState(() => _publishNow = v),
              title: const Text('立即发布'),
              subtitle: Text(
                _publishNow
                    ? '保存后立刻出现在活动列表，志愿者可见'
                    : '存为草稿：仅你自己可见，可稍后再发布',
                style: theme.textTheme.bodySmall,
              ),
              contentPadding: EdgeInsets.zero,
            ),

            const SizedBox(height: Spacing.lg),

            AppButton(
              label: _publishNow ? '发布活动' : '存为草稿',
              icon: _publishNow ? Icons.campaign_outlined : Icons.save_outlined,
              loading: _submitting,
              loadingLabel: '正在保存…',
              onPressed: _submitting ? null : _submit,
            ),

            const SizedBox(height: Spacing.sm),

            Text(
              '创建后会得到活动编号，可用于在列表里定位它。'
              '同一编号重复提交会更新原活动而不是新建。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 统一的输入框构造。
  ///
  /// 每个字段的错误文案从 `_fieldErrors` 取 —— 这样本地校验与服务端
  /// 返回的字段错误走同一套显示逻辑，不必写两遍。
  Widget _field({
    required String key,
    required TextEditingController controller,
    required String label,
    String? hint,
    bool required = false,
    int? maxLength,
    int maxLines = 1,
    TextInputType? keyboardType,
    bool mono = false,
  }) {
    final String? error = _fieldErrors[key];
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: TextField(
        controller: controller,
        enabled: !_submitting,
        maxLines: maxLines,
        keyboardType: keyboardType,
        inputFormatters: keyboardType == TextInputType.number
            ? <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly]
            : null,
        style: mono
            ? const TextStyle(fontFeatures: <FontFeature>[FontFeature.tabularFigures()])
            : null,
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          hintText: hint,
          errorText: error,
          errorMaxLines: 3,
          // 计数器只在接近上限时才有信息量；一直显示是噪声。
          counterText: maxLength == null ? null : '',
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) {
          // 改了字段就清掉它的错误 —— 否则错误提示会一直挂着，
          // 用户分不清"我改好了没有"。
          if (_fieldErrors.containsKey(key)) {
            setState(() => _fieldErrors = Map<String, String>.from(_fieldErrors)..remove(key));
          }
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// 子组件
// ═══════════════════════════════════════════════════════════════════════

/// 顶部的定位卡片。
class _LocationCard extends StatelessWidget {
  const _LocationCard({
    required this.locating,
    required this.hint,
    required this.lat,
    required this.lng,
    required this.onUseCurrent,
  });

  final bool locating;
  final String? hint;
  final String lat;
  final String lng;
  final VoidCallback? onUseCurrent;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasCoords = lat.trim().isNotEmpty && lng.trim().isNotEmpty;

    return AppCard(
      padding: const EdgeInsets.all(Spacing.md),
      highlight: hasCoords,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                hasCoords ? Icons.my_location : Icons.location_searching,
                size: 20,
                color: hasCoords
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  '签到点',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            hasCoords
                ? '已设置：$lat, $lng'
                : '还没设置坐标。用下方按钮取当前位置，最快。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: hasCoords
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
              fontFeatures: hasCoords
                  ? const <FontFeature>[FontFeature.tabularFigures()]
                  : null,
            ),
          ),
          if (hint != null) ...<Widget>[
            const SizedBox(height: Spacing.xs),
            Text(
              hint!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(height: Spacing.sm),
          AppButton(
            label: locating ? '正在定位…' : '用当前位置作为签到点',
            icon: Icons.my_location,
            variant: hasCoords
                ? AppButtonVariant.secondary
                : AppButtonVariant.primary,
            loading: locating,
            loadingLabel: '正在定位…',
            onPressed: onUseCurrent,
          ),
        ],
      ),
    );
  }
}

/// 分组标题 + 内容。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        ...children,
      ],
    );
  }
}

/// 时间选择行。
class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            suffixIcon: const Icon(Icons.event_outlined, size: 20),
          ),
          child: Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

/// 场地类型选择（影响默认签到半径）。
class _LocationTypeRow extends StatelessWidget {
  const _LocationTypeRow({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: const <ButtonSegment<String>>[
        ButtonSegment<String>(
          value: 'outdoor',
          label: Text('室外'),
          icon: Icon(Icons.wb_sunny_outlined, size: 18),
        ),
        ButtonSegment<String>(
          value: 'indoor',
          label: Text('室内'),
          icon: Icon(Icons.meeting_room_outlined, size: 18),
        ),
      ],
      selected: <String>{value},
      onSelectionChanged: onChanged == null
          ? null
          : (Set<String> s) => onChanged!(s.first),
    );
  }
}

/// 说明提示条。
/// 已读取到的场地网络摘要。
///
/// 刻意把 BSSID 与网段**都显示出来**，而不是只说"已配置"：
/// 发布者需要确认读到的是不是他站的这个场地（校园里同一个 SSID
/// 会有几十个 AP，BSSID 不同），否则配错了会让签到永远命中不了，
/// 而现象是"自动通过就是不生效"，极难排查。
class _NetworkSummary extends StatelessWidget {
  const _NetworkSummary({
    required this.bssids,
    required this.ipPrefixes,
    required this.onClear,
  });

  final List<String> bssids;
  final List<String> ipPrefixes;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final StatusVisual v = StatusVisual(label: '', tone: StatusTone.success);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: v.background,
        borderRadius: Radii.cardRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.check_circle_outline,
                  size: Sizes.iconSm, color: v.onBackground),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text('已记录场地网络', style: text.labelLarge?.copyWith(color: v.onBackground)),
              ),
              if (onClear != null)
                TextButton(
                  onPressed: onClear,
                  child: const Text('清除'),
                ),
            ],
          ),
          if (bssids.isNotEmpty)
            Text(
              '场地 Wi-Fi：${bssids.join('、')}（+20 分）',
              style: text.labelSmall?.copyWith(color: v.onBackground),
            ),
          if (ipPrefixes.isNotEmpty)
            Text(
              '校园网网段：${ipPrefixes.join('、')}（+10 分）',
              style: text.labelSmall?.copyWith(color: v.onBackground),
            ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.md),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 错误提示。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
