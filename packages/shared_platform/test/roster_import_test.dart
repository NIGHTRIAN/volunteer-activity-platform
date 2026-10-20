import 'package:flutter_test/flutter_test.dart';
import 'package:shared_platform/shared_platform.dart';

/// 名单文本解析。
///
/// ## 这组测试守的是一个真实报障
///
/// 真机反馈：**管理端手动输入时读取的行是错的**。
/// 根因是分隔符只认 `[\t,，;；]`、**不认空格**，于是
/// `2026101 张伟 13800000101` 被当成一个字段 →
/// 学号变成整行、姓名为空 → 报"学号或姓名为空"。
///
/// 用户看着自己明明填对了，却被告知没填 —— 这类问题必须靠测试钉住。
///
/// 另外三个前提也在这里固定下来：
///   * **学号与姓名长度不固定**（不能按长度切）
///   * **手机号不强制**（两列也能导）
///   * **学院是可选列**（有就记，没有不影响导入）
void main() {
  group('手动输入：空格分隔（本次报障的场景）', () {
    test('学号 姓名 手机号 —— 三列都能正确切出来', () {
      final RosterParseResult r = parseRosterText('2026101 张伟 13800000101');
      expect(r.entries, hasLength(1));
      final RosterEntry e = r.entries.single;
      expect(e.userNo, '2026101');
      expect(e.name, '张伟');
      expect(e.phone, '13800000101');
      expect(e.college, '');
    });

    test('多行空格分隔', () {
      final RosterParseResult r = parseRosterText(
        '2026101 张伟 13800000101\n'
        '2026102 李娜 13800000102\n',
      );
      expect(r.entries, hasLength(2));
      expect(r.entries[1].name, '李娜');
    });

    test('只有学号和姓名（手机号不强制）', () {
      final RosterParseResult r = parseRosterText('2026101 张伟\n2026102 李娜');
      expect(r.entries, hasLength(2));
      expect(r.entries.first.phone, '');
      expect(r.entries.first.isUsable, isTrue);
    });

    test('学号 姓名 学院（省略手机号）', () {
      final RosterParseResult r = parseRosterText('2026101 张伟 计算机学院');
      final RosterEntry e = r.entries.single;
      expect(e.phone, '', reason: '「计算机学院」不是手机号，不该被当手机号');
      expect(e.college, '计算机学院');
    });

    test('学号 姓名 学院 手机号（学院在手机号前面）', () {
      final RosterParseResult r = parseRosterText('2026101 张伟 计算机学院 13800000101');
      final RosterEntry e = r.entries.single;
      expect(e.userNo, '2026101');
      expect(e.name, '张伟');
      expect(e.college, '计算机学院');
      expect(e.phone, '13800000101');
    });

    test('学号 姓名 手机号 学院（手机号在学院前面）', () {
      final RosterParseResult r = parseRosterText('2026101 张伟 13800000101 计算机学院');
      final RosterEntry e = r.entries.single;
      expect(e.phone, '13800000101');
      expect(e.college, '计算机学院');
    });

    test('多个连续空格、全角空格都不产生空字段', () {
      for (final String sep in <String>['   ', '\u3000', ' \u3000 ']) {
        final RosterParseResult r =
            parseRosterText(<String>['2026101', '张伟', '13800000101'].join(sep));
        expect(r.entries.single.userNo, '2026101', reason: '分隔符「$sep」');
        expect(r.entries.single.name, '张伟');
        expect(r.entries.single.phone, '13800000101');
      }
    });

    test('制表符优先于空格：单元格内的空格保留（姓名可能带空格）', () {
      // Excel 粘贴给的是制表符；此时"张伟 老师"是一个单元格，不能被拆成两个人名
      final RosterParseResult r =
          parseRosterText('2026101\t张伟 老师\t13800000101');
      expect(r.entries.single.name, '张伟 老师');
      expect(r.entries.single.phone, '13800000101');
    });

    test('制表符两侧的空格会被裁掉', () {
      final RosterParseResult r =
          parseRosterText('2026101 \t 张伟 \t 13800000101');
      expect(r.entries.single.userNo, '2026101');
      expect(r.entries.single.name, '张伟');
      expect(r.entries.single.phone, '13800000101');
    });
  });

  group('长度不固定', () {
    test('短学号（2 位）也能识别——不按长度切', () {
      final RosterParseResult r = parseRosterText('A1 张三 13800000101');
      expect(r.entries.single.userNo, 'A1');
      expect(r.entries.single.name, '张三');
    });

    test('长学号 + 长姓名 + 学院', () {
      final RosterParseResult r =
          parseRosterText('202110010101 欧阳上官 信息与控制工程学院');
      final RosterEntry e = r.entries.single;
      expect(e.userNo, '202110010101');
      expect(e.name, '欧阳上官');
      expect(e.college, '信息与控制工程学院');
    });

    test('含字母的工号', () {
      final RosterParseResult r = parseRosterText('T2021A09 王强');
      expect(r.entries.single.userNo, 'T2021A09');
      expect(r.entries.single.name, '王强');
    });
  });

  group('表头识别', () {
    test('按表头顺序映射（学院在手机号前面也能对）', () {
      final RosterParseResult r = parseRosterText(
        '学号 姓名 学院 手机号\n'
        '2026101 张伟 计算机学院 13800000101\n',
      );
      expect(r.headerSkipped, isTrue);
      final RosterEntry e = r.entries.single;
      expect(e.userNo, '2026101');
      expect(e.name, '张伟');
      expect(e.college, '计算机学院');
      expect(e.phone, '13800000101');
    });

    test('表头顺序任意：手机号在前', () {
      final RosterParseResult r = parseRosterText(
        '手机号 姓名 学号\n'
        '13800000101 张伟 2026101\n',
      );
      final RosterEntry e = r.entries.single;
      expect(e.userNo, '2026101');
      expect(e.name, '张伟');
      expect(e.phone, '13800000101');
    });

    test('表头只有学号/姓名（两列）', () {
      final RosterParseResult r = parseRosterText(
        '学号 姓名\n2026101 张伟\n',
      );
      expect(r.headerSkipped, isTrue);
      expect(r.entries.single.name, '张伟');
    });

    test('表头里叫「序号」的列被忽略', () {
      final RosterParseResult r = parseRosterText(
        '序号 学号 姓名\n1 2026101 张伟\n2 2026102 李娜\n',
      );
      expect(r.entries, hasLength(2));
      expect(r.entries[0].userNo, '2026101', reason: '序号列不能被当成学号');
    });

    test('逗号分隔的表头 + 数据', () {
      final RosterParseResult r = parseRosterText(
        '学号,姓名,手机号\n2026101,张伟,13800000101\n',
      );
      expect(r.headerSkipped, isTrue);
      expect(r.entries.single.phone, '13800000101');
    });
  });

  group('首列是序号（无表头）', () {
    test('1 2026101 张伟 → 序号被丢掉', () {
      final RosterParseResult r = parseRosterText('1 2026101 张伟');
      expect(r.entries.single.userNo, '2026101');
      expect(r.entries.single.name, '张伟');
    });

    test('学号本身是数字时不能被误判成序号', () {
      final RosterParseResult r = parseRosterText('2026101 张伟 13800000101');
      expect(r.entries.single.userNo, '2026101');
    });
  });

  group('各种分隔符', () {
    test('制表符（Excel 粘贴）', () {
      final RosterParseResult r = parseRosterText('2026101\t张伟\t13800000101');
      expect(r.entries.single.phone, '13800000101');
    });

    test('中文逗号 / 分号 / 顿号 / 竖线', () {
      for (final String sep in <String>['，', '；', '、', '|', ',', ';']) {
        final RosterParseResult r =
            parseRosterText(<String>['2026101', '张伟', '13800000101'].join(sep));
        expect(r.entries.single.name, '张伟', reason: '分隔符「$sep」应被识别');
      }
    });

    test('CRLF 换行（Windows / Excel）', () {
      final RosterParseResult r =
          parseRosterText('2026101 张伟\r\n2026102 李娜\r\n');
      expect(r.entries, hasLength(2));
      expect(r.entries[1].name, '李娜');
    });
  });

  group('噪声与异常行', () {
    test('空行被跳过', () {
      final RosterParseResult r =
          parseRosterText('2026101 张伟\n\n\n2026102 李娜\n');
      expect(r.entries, hasLength(2));
    });

    test('「共 20 人」这类说明行被跳过并记录下来', () {
      final RosterParseResult r = parseRosterText(
        '2026101 张伟\n共 2 人\n2026102 李娜\n',
      );
      expect(r.entries, hasLength(2));
      expect(r.skippedLines, hasLength(1));
    });

    test('纯空白输入 → 0 行', () {
      expect(parseRosterText('   \n\n  ').entries, isEmpty);
    });

    test('多余列被忽略并计数', () {
      final RosterParseResult r =
          parseRosterText('2026101 张伟 13800000101 计算机学院 备注一 备注二');
      expect(r.ignoredExtraColumns, greaterThanOrEqualTo(1));
      expect(r.entries.single.college, '计算机学院');
    });
  });

  group('转成固定列序（给服务端）', () {
    test('rosterToRows 固定输出 [学号, 姓名, 手机号, 学院]', () {
      final List<List<String>> rows = rosterToRows(<RosterEntry>[
        const RosterEntry(userNo: '2026101', name: '张伟', phone: '13800000101', college: '计算机学院'),
        const RosterEntry(userNo: '2026102', name: '李娜'),
      ]);
      expect(rows[0], <String>['2026101', '张伟', '13800000101', '计算机学院']);
      expect(rows[1], <String>['2026102', '李娜', '', '']);
    });

    test('TSV 回填后能再解析回来（往返一致）', () {
      final List<RosterEntry> src = <RosterEntry>[
        const RosterEntry(userNo: '2026101', name: '张伟', phone: '13800000101', college: '计算机学院'),
        const RosterEntry(userNo: '2026102', name: '李娜', college: '外国语学院'),
      ];
      final RosterParseResult back = parseRosterText(rosterToTsv(src));
      expect(back.entries[0].college, '计算机学院');
      expect(back.entries[1].phone, '');
      expect(back.entries[1].college, '外国语学院');
    });

    test('摘要文案能说清"跳过表头/忽略多余列"', () {
      final RosterParseResult r = parseRosterText(
        '学号 姓名\n2026101 张伟 13800000101 多余列\n',
      );
      expect(r.summary, contains('1 行'));
      expect(r.summary, contains('表头'));
    });
  });

  group('空列保留（CSV/TSV 的列错位根源）', () {
    test('制表符分隔且中间为空 → 保持列位置（手机号空、学院在第 4 列）', () {
      final RosterParseResult r =
          parseRosterText('2026201\t张三\t\t计算机学院');
      final RosterEntry e = r.entries.single;
      expect(e.userNo, '2026201');
      expect(e.name, '张三');
      expect(e.phone, '', reason: '空手机号不能被跳过');
      expect(e.college, '计算机学院', reason: '学院不能顶到手机号列');
    });

    test('逗号分隔且中间为空 → 同上', () {
      final RosterParseResult r = parseRosterText('2026201,张三,,计算机学院');
      final RosterEntry e = r.entries.single;
      expect(e.phone, '');
      expect(e.college, '计算机学院');
    });

    test('空格分隔不做空列推断（连续空格只当对齐）', () {
      final RosterParseResult r = parseRosterText('2026201   张三   计算机学院');
      expect(r.entries.single.college, '计算机学院');
      expect(r.entries.single.phone, '');
    });

    test('制表符行尾空列不影响解析', () {
      final RosterParseResult r = parseRosterText('2026203\t王强\t\t');
      expect(r.entries.single.name, '王强');
      expect(r.entries.single.college, '');
    });
  });
}
