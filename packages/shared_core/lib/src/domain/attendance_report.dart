import '../contract/time_and_geo.dart';
import 'enums.dart';
import 'json_utils.dart';

/// 考勤汇总的一行（`GET /activities/{id}/attendance` 的 `rows[]`）。
///
/// ## 为什么把「完成率」原样透出，而不是只给一个等级
///
/// 决策 D-7 定的判据是"完成率 ≥0.7 记 partial"。只给一个标签，
/// 读的人无法判断"这个 partial 到底是差一点还是差很多"——而这正是
/// 争议时双方真正要谈的东西。把百分比摆出来，大家看的是同一个数字。
///
/// ## 字段来源（服务端实际下发的键名）
///
/// | 本模型 | 服务端键 |
/// |---|---|
/// | [done] | `attendanceDone` |
/// | [missed] | `attendanceMissed` |
/// | [excused] | `attendanceExcused` |
/// | [rate] | `attendanceRate`（0–1，无已定案任务时为 `null`） |
/// | [summary] | `attendanceSummary` |
class AttendanceSummaryRow {
  const AttendanceSummaryRow({
    required this.userNo,
    required this.name,
    required this.summary,
    this.done = 0,
    this.missed = 0,
    this.excused = 0,
    this.rate,
    this.checkinStatus,
  });

  /// 学号 / 工号。
  final String userNo;

  /// 姓名。
  final String name;

  /// 考勤等级。
  final AttendanceSummary summary;

  /// 已完成（按时响应）的次数。
  final int done;

  /// 已超时（未响应）的次数。
  final int missed;

  /// 已豁免的次数（活动取消或临时调整，**不计入分母**）。
  final int excused;

  /// 完成率 = done / (done + missed)。
  ///
  /// 无已定案任务时为 `null` —— 而不是 0。
  /// 这个区别很重要："0%" 会被读成"一次都没完成"，
  /// 而 `null` 的含义是"还没有可判定的事"（例如活动刚开始，
  /// 抽查尚未发生）。两者在汇总表里必须分开呈现。
  final double? rate;

  /// 签到状态（服务端在汇总里一并下发）。
  final ParticipantCheckinStatus? checkinStatus;

  /// 已定案的任务数（分母）。
  int get settled => done + missed;

  /// 完成率百分比（无数据时返回 `null`）。
  int? get ratePercent => rate == null ? null : (rate! * 100).round();

  /// 是否**没有任何已定案任务**。
  ///
  /// 此时等级必然是 `insufficient`，但那不代表这个人有问题——
  /// 界面应当用中性措辞（"尚未产生可判定记录"）而不是"证据不足"，
  /// 后者听起来像是指控。
  bool get hasNoSettledTask => settled == 0;

  factory AttendanceSummaryRow.fromJson(Map<String, dynamic> json) =>
      AttendanceSummaryRow(
        userNo: jsonStringOr(json['userNo'], ''),
        name: jsonStringOr(json['name'], ''),
        summary: AttendanceSummary.fromWire(json['attendanceSummary']),
        done: jsonIntOr(json['attendanceDone'], 0),
        missed: jsonIntOr(json['attendanceMissed'], 0),
        excused: jsonIntOr(json['attendanceExcused'], 0),
        rate: jsonDouble(json['attendanceRate']),
        checkinStatus: json['checkinStatus'] == null
            ? null
            : ParticipantCheckinStatus.fromWire(json['checkinStatus']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userNo': userNo,
        'name': name,
        'attendanceSummary': summary.wire,
        'attendanceDone': done,
        'attendanceMissed': missed,
        'attendanceExcused': excused,
        if (rate != null) 'attendanceRate': rate,
        if (checkinStatus != null) 'checkinStatus': checkinStatus!.wire,
      };
}

/// 考勤汇总整体（`GET /activities/{id}/attendance`）。
class AttendanceReport {
  const AttendanceReport({
    required this.rows,
    this.disclaimer = '',
    this.serverTime,
  });

  /// 明细行。
  final List<AttendanceSummaryRow> rows;

  /// 免责声明。**由服务端下发**，客户端不自行编辑。
  final String disclaimer;

  final DateTime? serverTime;

  /// 全勤人数。
  int get fullCount =>
      rows.where((AttendanceSummaryRow r) => r.summary == AttendanceSummary.full).length;

  /// 有超时记录的人数。
  int get partialCount =>
      rows.where((AttendanceSummaryRow r) => r.summary == AttendanceSummary.partial).length;

  /// 证据不足人数（**不是缺席**）。
  int get insufficientCount => rows
      .where((AttendanceSummaryRow r) => r.summary == AttendanceSummary.insufficient)
      .length;

  factory AttendanceReport.fromJson(Map<String, dynamic> json) => AttendanceReport(
        rows: jsonObjectList(json['rows'], AttendanceSummaryRow.fromJson),
        disclaimer: jsonStringOr(json['disclaimer'], ''),
        serverTime: TimeFormat.tryParse(json['serverTime']),
      );
}
