/// 邀请信息的**分享文本**与**解析**。
///
/// ## 为什么需要这个
///
/// 志愿者要绑活动，需要三样东西：**活动编号 + 学号 + 邀请码**。
/// 真机测试反馈很直接：
///
///   * 发布者要手工把三样东西分别念/抄给志愿者，**容易漏、容易错**；
///   * 志愿者要对着微信里的三段文字，往三个输入框里分别填 —— 极易填串；
///   * 活动编号较长（例如 `demo-act-library`）时，手抄基本不可能。
///
/// 所以做两件事，且两端共用同一份格式：
///
///   1. 发布者点一下就能复制**一整段**（带标签，人可读）；
///   2. 志愿者点一下「粘贴邀请信息」，App 自动把三个字段填好。
///
/// ## 为什么带中文标签而不是固定三行
///
/// 固定顺序（第一行活动、第二行学号……）看起来很简洁，但一旦对方
/// 多复制了一行标题、或少复制一行，就会**整体错位**，而且错得无声无息
/// （活动编号被填进学号框，报"活动不存在"）。
///
/// 带标签的文本即使多了标题、少了空行、调换了顺序，也能被正确解析。
library;

/// 一段可分享、可解析的邀请信息。
class InviteShare {
  const InviteShare({
    required this.activityId,
    required this.userNo,
    required this.inviteCode,
    this.activityTitle,
    this.studentName,
  });

  /// 活动编号（服务端活动 id 或外部编号）。
  final String activityId;

  /// 学号 / 工号。
  final String userNo;

  /// 一次性邀请码。
  final String inviteCode;

  /// 活动名称（仅用于展示，解析时可缺）。
  final String? activityTitle;

  /// 学生姓名（仅用于展示，解析时可缺）。
  final String? studentName;

  /// 生成分享文本。
  ///
  /// 形如：
  /// ```
  /// 【志愿活动】图书馆书架整理志愿服务
  /// 活动编号：12
  /// 学号：2021001
  /// 邀请码：BMJSL7XE
  ///
  /// 打开「志愿活动」App，点「粘贴邀请信息」即可自动填入。
  /// ```
  String toText() {
    final StringBuffer b = StringBuffer();
    if (activityTitle != null && activityTitle!.trim().isNotEmpty) {
      b.writeln('【志愿活动】${activityTitle!.trim()}');
    }
    if (studentName != null && studentName!.trim().isNotEmpty) {
      b.writeln('姓名：${studentName!.trim()}');
    }
    b.writeln('活动编号：$activityId');
    b.writeln('学号：$userNo');
    b.writeln('邀请码：$inviteCode');
    b.writeln();
    b.write('打开「志愿活动」App，点「粘贴邀请信息」即可自动填入。');
    return b.toString();
  }

  /// 从任意文本里解析。
  ///
  /// 宽容策略（都有用例覆盖）：
  ///   * 标签后跟冒号、中文冒号或空格都行；
  ///   * 多余的行（标题、空行、说明）忽略；
  ///   * 三行顺序任意；
  ///   * 「工号」「活动码」「活动 ID」等常见别名都认。
  ///
  /// 三个字段**缺任意一个就返回 null** —— 宁可让用户自己填，
  /// 也不要猜错后把错误值填进输入框（那种情况排查起来更费劲）。
  static InviteShare? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final String text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final String? activityId = _field(text, <String>[
      '活动编号',
      '活动码',
      '活动ID',
      '活动 ID',
      '活动id',
      '活动',
    ]);
    final String? userNo = _field(text, <String>['学号', '工号', '学生学号']);
    final String? inviteCode = _field(text, <String>['邀请码', '邀请代码', '邀请']);

    if (activityId == null || userNo == null || inviteCode == null) {
      return null;
    }

    final String? title = _loose(text, <String>['【志愿活动】', '活动名称']);
    final String? name = _field(text, <String>['姓名']);

    return InviteShare(
      activityId: activityId,
      userNo: userNo,
      inviteCode: inviteCode,
      activityTitle: title,
      studentName: name,
    );
  }

  /// 按标签取值。标签按长度**从长到短**试，避免「活动」先于「活动编号」命中。
  static String? _field(String text, List<String> labels) {
    final List<String> sorted = List<String>.of(labels)
      ..sort((String a, String b) => b.length.compareTo(a.length));
    for (final String label in sorted) {
      // 标签 + 可选空白 + 可选冒号 + 可选空白 + 值
      final RegExp re = RegExp(
        '${RegExp.escape(label)}\\s*[:：]?\\s*([A-Za-z0-9][A-Za-z0-9_-]*)',
      );
      final RegExpMatch? m = re.firstMatch(text);
      if (m != null) {
        final String? v = m.group(1);
        if (v != null && v.isNotEmpty) {
          return v;
        }
      }
    }
    return null;
  }

  /// 宽松取值：整行剩余部分都算（用于中文标题/姓名）。
  static String? _loose(String text, List<String> labels) {
    for (final String label in labels) {
      final RegExp re = RegExp('${RegExp.escape(label)}\\s*[:：]?\\s*([^\\n]+)');
      final RegExpMatch? m = re.firstMatch(text);
      if (m != null) {
        final String v = (m.group(1) ?? '').trim();
        if (v.isNotEmpty) {
          return v;
        }
      }
    }
    return null;
  }

  /// 是否三个字段齐全（便于 UI 判断按钮可用状态）。
  bool get isComplete =>
      activityId.isNotEmpty && userNo.isNotEmpty && inviteCode.isNotEmpty;

  @override
  String toString() =>
      'InviteShare(activityId: $activityId, userNo: $userNo, inviteCode: $inviteCode)';
}
