import 'package:flutter_test/flutter_test.dart';
import 'package:shared_platform/shared_platform.dart';

/// Wi-Fi IP 选取规则。
///
/// ## 这条规则为什么值得单独测
///
/// 真机（Redmi Note 12T Pro / Android 15，Wi-Fi 与移动数据同时开启）暴露：
///
/// ```
/// ccmni1  10.176.238.211/8     ← 蜂窝
/// wlan0   10.3.229.13/16       ← Wi-Fi
/// ```
///
/// `NetworkInfo.getWifiIP()` 返回的是**蜂窝**地址 `10.176.238.211`。
/// 于是「校园网命中」这项加分整体失效：
///
/// * 发布者录到的网段与场地 Wi-Fi 无关；
/// * 只开 Wi-Fi 的志愿者上报 `10.3.`，永远命中不了 `10.176.`；
/// * 结果是**每次签到都要人工确认**，而现象看起来像"自动通过不生效"。
///
/// 复现需要双链路真机，所以把"按接口名挑选"的规则做成纯函数单独测。
/// 测试里的接口名与地址都取自真机实测值。
void main() {
  group('pickWifiAddress · 真机双链路场景', () {
    test('蜂窝 + Wi-Fi 并存时必须选 Wi-Fi（而不是列表第一个）', () {
      // 顺序刻意让蜂窝在前 —— 这正是原 bug 的成因：
      // 取"第一个非回环地址"就会拿到蜂窝。
      final String? ip = ConnectivityService.pickWifiAddress(<(String, String)>[
        ('ccmni1', '10.176.238.211'),
        ('wlan0', '10.3.229.13'),
      ]);
      expect(ip, '10.3.229.13',
          reason: '必须选中 Wi-Fi 地址，否则校园网加分永远命中不了');
    });

    test('只有蜂窝时返回 null（不能把蜂窝地址当成 Wi-Fi）', () {
      final String? ip = ConnectivityService.pickWifiAddress(<(String, String)>[
        ('ccmni1', '10.176.238.211'),
        ('rmnet0', '10.176.238.212'),
      ]);
      expect(ip, isNull,
          reason: '没有 Wi-Fi 时宁可没有，也不要上报蜂窝地址污染判定');
    });

    test('热点接口 swlan0 / ap0 也要认（手机开热点时）', () {
      expect(
        ConnectivityService.pickWifiAddress(<(String, String)>[
          ('ccmni1', '10.176.1.1'),
          ('swlan0', '192.168.72.200'),
        ]),
        '192.168.72.200',
      );
      expect(
        ConnectivityService.pickWifiAddress(<(String, String)>[
          ('ccmni1', '10.176.1.1'),
          ('ap0', '192.168.43.1'),
        ]),
        '192.168.43.1',
      );
    });

    test('排除 Wi-Fi Direct（p2p0）与回环、链路本地地址', () {
      final String? ip = ConnectivityService.pickWifiAddress(<(String, String)>[
        ('p2p0', '192.168.49.1'),
        ('wlan0', '169.254.10.20'), // 未拿到 DHCP
      ]);
      expect(ip, isNull, reason: 'p2p0 不是上网口，169.254 是链路本地地址');
    });

    test('wlan 优先于 eth（有线转接场景）', () {
      expect(
        ConnectivityService.pickWifiAddress(<(String, String)>[
          ('eth0', '192.168.1.50'),
          ('wlan0', '10.3.229.13'),
        ]),
        '10.3.229.13',
      );
    });
  });
}
