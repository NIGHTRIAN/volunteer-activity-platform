/// 应用级常量。
///
/// ## 为什么名称要写在这里而不是散在界面里
///
/// 两个 App 的标题会出现在登录页、AppBar、导出文件名、错误提示等多个地方。
/// 一旦散落，改名时必然漏掉几处——而漏掉的那处往往是最少被看到的页面。
library;

/// 平台名称。
const String kPlatformName = '志愿活动信息平台';

/// 用户端名称（面向志愿者）。
const String kUserAppName = '志愿活动';

/// 管理端名称（面向发布者）。
const String kAdminAppName = '志愿活动 · 管理端';

/// 用户端一句话说明。
const String kUserAppTagline = '扫码签到，现场确认';

/// 管理端一句话说明。
const String kAdminAppTagline = '发布活动，现场点名';

/// 隐私说明（方案 §7 要求明示采集范围）。
const String kPrivacySummary =
    '本应用仅在签到与在岗确认时按需获取一次定位，不采集持续轨迹，'
    '不读取通讯录或相册。手机号仅用于发布者现场联系，导出默认脱敏。';
