/// 契约常量：错误码表。
///
/// ## 来源：《网页开发方案》§6.1（权威）
///
/// > **错误码**：`0` 成功、`40001` 参数错误、`40101` 未认证、`40301` 越权、
/// > `40401` 不存在、`40901` 状态冲突、`42901` 限流、`50001` 服务异常。
///
/// ⚠️ 早期版本我按「`1xxxx` 通用 / `2xxxx` 认证 / `3xxxx` 业务」自造了一套码值，
/// 那是**错的**——网页方案已经给出了正式的 8 个码值。已全部改为方案规定值，
/// 并把「业务细分原因」从**错误码**移到 **`errors[].field` + 文案**，
/// 因为方案只授权了这 8 个码。
///
/// 这样做的后果与收益：
///   * 收益：契约一致，后端按方案实现即可；
///   * 后果：客户端不能再靠码值区分"邀请码错"与"邀请码过期"这类细分，
///     必须读文案或字段名。因此本文件为每种细分保留一个**语义枚举**，
///     但它们的 `value` 会映射到方案授权的 8 个码之一。
library;

/// 平台统一错误码。
///
/// 枚举**名字**表达业务细分语义，`value` 是**方案授权的线码值**。
/// 客户端只应比较枚举名，不要比较 `value`——线码值可能因服务端细化而合并。
enum ApiErrorCode {
  // ── 成功 ─────────────────────────────────────────────────────────────
  /// 成功（方案：`0`）。
  ok(0, '成功'),

  // ── 40001 参数错误 ───────────────────────────────────────────────────
  /// 请求参数校验失败；`errors[]` 给出字段级原因。
  badRequest(40001, '请求参数有误'),

  /// 幂等键冲突：同键不同体（`X-Idempotency-Key` 24h 窗口内）。
  idempotencyConflict(40001, '重复请求且内容不一致'),

  /// 接口版本不支持（`X-Api-Version`）。方案 §1.4 要求预留版本协商。
  apiVersionUnsupported(40001, '当前版本过旧，请升级应用'),

  /// 不在签到时间窗内。方案 §6.4.5 判定顺序①。
  outsideCheckinWindow(40001, '不在签到时段内'),

  /// 取消原因不足 5 字（方案 §5.3 前置条件）。
  cancelReasonTooShort(40001, '取消原因至少 5 个字'),

  // ── 40101 未认证 ─────────────────────────────────────────────────────
  /// 未携带或携带了无效令牌。
  unauthorized(40101, '登录状态已失效'),

  /// 管理员邀请码错误（验收 A3：连续 5 次锁定 10 分钟）。
  adminCodeInvalid(40101, '邀请码错误'),

  /// 连续失败次数超限，账号锁定（方案 §6.3）。
  adminCodeLocked(40101, '错误次数过多，账号已锁定'),

  /// 一次性邀请码不存在、已使用或已过期（方案 §4.7）。
  inviteCodeInvalid(40101, '邀请码无效或已被使用'),

  /// 活动级授权已过期：活动终态 + 7 天（方案 §4.7）。
  grantExpired(40101, '本次活动授权已过期'),

  /// 管理端令牌失效：名下活动全部终态后 24 小时（方案 §6.3）。
  adminTokenExpired(40101, '管理端登录已过期，请重新登录'),

  // ── 40301 越权 ───────────────────────────────────────────────────────
  /// 越权操作他人活动（方案 §6.3：服务端逐接口校验 `ownerId`）。验收 A4 原文码值。
  forbidden(40301, '无权操作该活动'),

  /// 学号不在该活动名单中（方案 §6.3 绑定校验）。验收 A10。
  notInParticipantList(40301, '你不在本次活动名单中'),

  /// 姓名或手机号后四位与名单不匹配（移动端方案 §14.1-2 二次校验）。
  identityMismatch(40301, '姓名或手机号后四位不匹配'),

  /// 该身份已绑定其他设备（方案 §6.3 设备指纹绑定）。
  deviceAlreadyBound(40301, '该身份已绑定其他设备'),

  /// 设备令牌与绑定设备不一致。
  deviceMismatch(40301, '设备校验未通过，请重新绑定'),

  /// 该接口不支持当前身份（例如志愿者调用管理端接口）。
  roleNotAllowed(40301, '当前身份无权访问'),

  // ── 40401 不存在 ─────────────────────────────────────────────────────
  /// 活动不存在，或已随 7 天留存期销毁（验收 A21）。
  activityNotFound(40401, '活动不存在或已过留存期'),

  /// 导出文件不存在或尚未生成。
  exportNotFound(40401, '导出文件不存在或已过期'),

  /// 在岗任务不存在。
  attendanceTaskNotFound(40401, '在岗任务不存在'),

  // ── 40901 状态冲突 ───────────────────────────────────────────────────
  /// 非法状态转移（方案 §5.1 状态机）。
  activityStateInvalid(40901, '当前活动状态不支持该操作'),

  /// 乐观锁冲突（方案 §4.1 `version`）。
  versionConflict(40901, '状态已更新，请重试'),

  /// 规则快照已冻结，关键字段禁改（方案 §5.2）。
  activityRuleFrozen(40901, '已发布活动的关键字段不可修改'),

  /// 已有一条有效签到（方案 §4.4：`(activityId, userId)` 唯一）。
  alreadyCheckedIn(40901, '你已完成签到'),

  /// 名单条目重复（活动内 `userNo` 唯一，方案 §4.3）。
  participantDuplicated(40901, '名单中已存在该学号'),

  /// 活动名额已满。
  quotaExceeded(40901, '活动名额已满'),

  /// 在岗任务已超时或已完成，不能重复确认（方案 §6.4.6）。
  attendanceTaskClosed(40901, '该在岗确认已结束'),

  // ── 42901 限流 ───────────────────────────────────────────────────────
  /// 触发限流（方案 §6.5：单 Key/用户 60 次/分钟；签到 10 次/小时；突发桶 20）。
  tooManyRequests(42901, '操作过于频繁，请稍后重试'),

  // ── 50001 服务异常 ───────────────────────────────────────────────────
  /// 服务暂时不可用（方案 §9：提示且不丢弃本地数据）。
  serverError(50001, '服务暂时不可用，请稍后重试'),

  // ── 仅客户端使用（不来自服务端）───────────────────────────────────────
  /// 设备离线：本地队列已保存，尚未上报。
  offlineQueued(-1, '已保存到本地，联网后自动同步'),

  /// 请求超时且已用尽退避重试。
  networkTimeout(-2, '网络不佳，请稍后重试'),

  /// 客户端未能识别的响应。
  unknown(-99, '未知错误');

  const ApiErrorCode(this.value, this.defaultMessage);

  /// 与服务端约定的数值码（**方案授权的 8 个码之一**）。
  final int value;

  /// 展示给用户的中文默认文案（服务端 `msg` 可覆盖）。
  final String defaultMessage;

  /// 由服务端码值反查**错误族**。
  ///
  /// ## ⚠️ 这是不可逆的，务必理解
  ///
  /// 方案只授权 8 个码值，而业务有几十种细分，因此**多个枚举共享同一个 `value`**。
  /// 反查只能得到该码值的"族代表"，**无法还原出精确的细分**：
  ///
  /// ```
  /// 40301 可能是 forbidden（越权）、notInParticipantList（不在名单）、
  ///             identityMismatch（二次校验失败）、deviceMismatch（设备不符）……
  /// ```
  ///
  /// 那 UI 怎么显示准确原因？靠**服务端下发的 `msg` 文案**，以及
  /// `errors[].field`（字段级错误）。这也是方案 §7.2「字段级错误定位」的用意。
  ///
  /// 判断"该做什么"时请用族级谓词（[isAuthFailure] / [isForbidden] / …），
  /// 不要用 `==` 比拼具体枚举名——那会在服务端细化错误时静默失效。
  static ApiErrorCode fromValue(int? value) {
    if (value == null) {
      return ApiErrorCode.unknown;
    }
    return _representatives[value] ?? ApiErrorCode.unknown;
  }

  /// 每个**方案授权码值**的族代表。显式列出而不是靠枚举声明顺序，
  /// 避免"改动枚举顺序导致错误族静默变化"这种极难排查的问题。
  static const Map<int, ApiErrorCode> _representatives = <int, ApiErrorCode>{
    0: ApiErrorCode.ok,
    40001: ApiErrorCode.badRequest,
    40101: ApiErrorCode.unauthorized,
    40301: ApiErrorCode.forbidden,
    40401: ApiErrorCode.activityNotFound,
    40901: ApiErrorCode.versionConflict,
    42901: ApiErrorCode.tooManyRequests,
    50001: ApiErrorCode.serverError,
    -1: ApiErrorCode.offlineQueued,
    -2: ApiErrorCode.networkTimeout,
    -99: ApiErrorCode.unknown,
  };

  /// 本错误码是否为方案授权的 8 个值之一（不含客户端本地码）。
  bool get isAuthorizedWireCode => _representatives.containsKey(value);

  /// 是否为客户端本地产生的码（未经过服务端）。
  bool get isClientSide => value < 0;

  /// 是否属于「参数错误」类。
  bool get isBadRequest => value == 40001;

  /// 是否属于「未认证」类 —— 应清理令牌并跳转登录/绑定。
  bool get isAuthFailure => value == 40101;

  /// 是否属于「越权」类。
  ///
  /// ⚠️ 注意：`40301` 同时也用于「不在名单中」这类业务拒绝。
  /// 因此**不能**仅凭 `40301` 就清令牌——见 [shouldClearToken]。
  bool get isForbidden => value == 40301;

  /// 是否属于「不存在」类。
  bool get isNotFound => value == 40401;

  /// 是否属于「状态冲突」类 —— 应刷新后重试。
  bool get isConflict => value == 40901;

  /// 是否限流。
  bool get isRateLimited => value == 42901;

  /// 是否服务端异常 —— 可重试。
  bool get isServerError => value == 50001;

  /// 是否应触发「清理失效令牌并跳转登录/绑定」（方案 §9 的 401 处理口径）。
  ///
  /// ⚠️ 只有 `40101` 才算令牌失效。
  /// **`40301` 不是**：它涵盖越权（`ownerId` 不符）与「不在名单中」，
  /// 这两种情况下令牌本身是好的，清掉会让用户白重登一次，而且重登也解决不了。
  bool get shouldClearToken => value == 40101;
}

/// HTTP 状态码 → 平台错误码的兜底映射（响应体不可用或格式异常时使用）。
ApiErrorCode mapHttpStatusToErrorCode(int statusCode) {
  switch (statusCode) {
    case 400:
      return ApiErrorCode.badRequest;
    case 401:
      return ApiErrorCode.unauthorized;
    case 403:
      return ApiErrorCode.forbidden;
    case 404:
      return ApiErrorCode.activityNotFound;
    case 409:
      return ApiErrorCode.versionConflict;
    case 429:
      return ApiErrorCode.tooManyRequests;
    default:
      if (statusCode >= 500) {
        return ApiErrorCode.serverError;
      }
      return ApiErrorCode.unknown;
  }
}
