import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_platform/shared_platform.dart';

/// Excel / CSV 名单导入的解析逻辑。
///
/// ## 为什么用**真实 xlsx 生成的 XML**做夹具
///
/// 手搓一份"我以为的 xlsx" XML 几乎必然测不出真问题：真实导出文件里有
/// 数字字符实体（openpyxl 会把中文写成 `&#23398;`）、有共享字符串表、
/// 有中间空掉的单元格（`<c r="A2">` 后面直接就是 `<c r="D2">`）。
///
/// 所以夹具是用 **openpyxl（内联字符串）** 与 **XlsxWriter（共享字符串）**
/// 生成真实 .xlsx 后、把里面两个 XML 原样取出来的 ——
/// 覆盖了国内用户最可能遇到的两种导出格式。
///
/// 生成脚本的要点记在这里，便于将来重新生成：
/// ```python
/// ws.append(["学号", "姓名", "手机号"])       # openpyxl → t="inlineStr"
/// sh.write(r, c, "张伟")                      # xlsxwriter → t="s"（共享字符串）
/// ```
void main() {
  final Directory fixtures = Directory('test/fixtures');

  String read(String name) => File('${fixtures.path}/$name').readAsStringSync();

  group('解析 xlsx · 内联字符串（openpyxl 导出）', () {
    late List<List<String>> rows;

    setUpAll(() {
      rows = SpreadsheetImport.parseXlsxSheet(
        // openpyxl 默认不写 sharedStrings.xml
        sharedStringsXml: null,
        sheetXml: read('roster_inline.sheet1.xml'),
      );
    });

    test('读出全部行与列', () {
      expect(rows.length, 3);
      expect(rows.first.length, 3);
    });

    test('中文被正确解码（文件里是 &#23398; 这类数字实体）', () {
      expect(rows[0], <String>['学号', '姓名', '手机号']);
      expect(rows[1], <String>['2021001', '张伟', '13800000001']);
      expect(rows[2][1], '李娜');
    });
  });

  group('解析 xlsx · 共享字符串（XlsxWriter 导出）', () {
    late List<List<String>> rows;

    setUpAll(() {
      rows = SpreadsheetImport.parseXlsxSheet(
        sharedStringsXml: read('roster_shared.sharedStrings.xml'),
        sheetXml: read('roster_shared.sheet1.xml'),
      );
    });

    test('共享字符串按索引正确还原', () {
      expect(rows[0], <String>['学号', '姓名', '手机号', '备注']);
      expect(rows[1][1], '张伟');
    });

    test('中间空单元格必须**保留列位置**（否则姓名会错位到手机号列）', () {
      // 第 3 行在 XML 里只有 A3、C3 两个 <c>，B 列是空的
      expect(rows[2].length, greaterThanOrEqualTo(3));
      expect(rows[2][0], '2022002');
      expect(rows[2][1], '', reason: 'B 列在表里是空的，不能把后面的值往前挤');
      expect(rows[2][2], '13800000012', reason: '手机号必须还在第 3 列');
    });

    test('特殊字符 & < > 被正确反转义', () {
      final List<String> row = rows[3];
      expect(row[1], '李&娜<测试>');
    });
  });

  group('解析 xlsx · 边界', () {
    test('没有 sharedStrings 且用 t="s" 时不崩（退回空串）', () {
      final List<List<String>> rows = SpreadsheetImport.parseXlsxSheet(
        sharedStringsXml: null,
        sheetXml: '<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData>',
      );
      // 整行都是空 → 该行被丢弃
      expect(rows, isEmpty);
    });

    test('空工作表返回空列表', () {
      expect(
        SpreadsheetImport.parseXlsxSheet(sharedStringsXml: null, sheetXml: ''),
        isEmpty,
      );
    });

    test('数字单元格（没有 t 属性）按文本取', () {
      final List<List<String>> rows = SpreadsheetImport.parseXlsxSheet(
        sharedStringsXml: null,
        sheetXml: '<sheetData><row r="1"><c r="A1"><v>2021001</v></c></row></sheetData>',
      );
      expect(rows.single.single, '2021001');
    });

    test('列字母换算：AA 之后仍正确', () {
      final List<List<String>> rows = SpreadsheetImport.parseXlsxSheet(
        sharedStringsXml: null,
        sheetXml: '<sheetData><row r="1">'
            '<c r="A1" t="inlineStr"><is><t>a</t></is></c>'
            '<c r="AA1" t="inlineStr"><is><t>z</t></is></c>'
            '</row></sheetData>',
      );
      expect(rows.single.length, 27, reason: 'A..AA 共 27 列');
      expect(rows.single.first, 'a');
      expect(rows.single.last, 'z');
    });
  });

  group('表头识别', () {
    test('首行是表头时自动丢掉（报名表几乎都有表头）', () {
      final List<List<String>> rows = SpreadsheetImport.dropHeaderRow(<List<String>>[
        <String>['学号', '姓名', '手机号'],
        <String>['2021001', '张伟', '13800000001'],
      ]);
      expect(rows.length, 1);
      expect(rows.single.first, '2021001');
    });

    test('首行是数据时**不能**误丢', () {
      final List<List<String>> rows = SpreadsheetImport.dropHeaderRow(<List<String>>[
        <String>['2021001', '张伟', '13800000001'],
        <String>['2021002', '李娜', '13800000002'],
      ]);
      expect(rows.length, 2, reason: '没有表头特征时不能丢第一行');
    });

    test('空表不崩', () {
      expect(SpreadsheetImport.dropHeaderRow(<List<String>>[]), isEmpty);
    });
  });

  group('解析 CSV / 粘贴文本', () {
    test('逗号 / 制表符 / 中文逗号 / 分号都认', () {
      final List<List<String>> rows = SpreadsheetImport.parseDelimitedText(
        '2021001,张伟,13800000001\n'
        '2021002\t李娜\t13800000002\n'
        '2021003，王强，13800000003\n'
        '2021004；赵六；13800000004',
      );
      expect(rows.length, 4);
      expect(rows[1], <String>['2021002', '李娜', '13800000002']);
      expect(rows[3].first, '2021004');
    });

    test('空行被跳过', () {
      final List<List<String>> rows =
          SpreadsheetImport.parseDelimitedText('a,b\n\n\nc,d\n');
      expect(rows.length, 2);
    });

    test('全是空白的文本返回空', () {
      expect(SpreadsheetImport.parseDelimitedText('   \n\n  '), isEmpty);
    });
  });

  group('转成预览文本', () {
    test('rowsToTsv 用制表符连接，便于回填到输入框', () {
      expect(
        rowsToTsv(<List<String>>[
          <String>['a', 'b'],
          <String>['c', 'd'],
        ]),
        'a\tb\nc\td',
      );
    });

    test('TSV 再解析回来内容不变（往返一致）', () {
      final List<List<String>> src = <List<String>>[
        <String>['2021001', '张伟', '13800000001'],
        <String>['2021002', '李娜', ''],
      ];
      final List<List<String>> back =
          SpreadsheetImport.parseDelimitedText(rowsToTsv(src));
      expect(back[0], src[0]);
      // 末尾空列在文本里会变成行尾制表符，解析时会被裁掉 —— 这是可接受的
      expect(back[1].sublist(0, 2), src[1].sublist(0, 2));
    });
  });

  group('分隔文本必须保留空列（列错位的根源）', () {
    test('CSV 中间的空单元格保留位置', () {
      final List<List<String>> rows = SpreadsheetImport.parseDelimitedText(
        '2026201,张三,,计算机学院\n',
      );
      expect(rows.single, <String>['2026201', '张三', '', '计算机学院'],
          reason: '空手机号那一格不能被吞掉，否则学院会顶到手机号列');
    });

    test('CSV 行尾的空单元格保留', () {
      final List<List<String>> rows = SpreadsheetImport.parseDelimitedText(
        '2026203,王强,,\n',
      );
      expect(rows.single, <String>['2026203', '王强', '', '']);
    });

    test('制表符分隔同样保留空列', () {
      final List<List<String>> rows =
          SpreadsheetImport.parseDelimitedText('2026201\t张三\t\t计算机学院\n');
      expect(rows.single.length, 4);
      expect(rows.single[2], '');
    });
  });
}
