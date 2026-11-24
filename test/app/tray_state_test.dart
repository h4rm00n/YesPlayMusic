// 托盘开关：默认开，setTray 会写进 prefs.json（lib/tray.dart 消费这个值）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yesplaymusic/state.dart';

Map<String, Object?> _prefs() {
  final f = File('${AppState.supportDir()}/prefs.json');
  // 从没改过任何设置时还没有这个文件
  return f.existsSync()
      ? (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>()
      : {};
}

void main() {
  test('tray 默认开，setTray 持久化', () {
    final app = AppState();
    expect(app.tray, isTrue);
    expect(_prefs().containsKey('tray'), isFalse);

    app.setTray(false);
    expect(app.tray, isFalse);
    expect(_prefs()['tray'], isFalse);

    // 再起一个 AppState 模拟重启：从盘上读回关闭状态
    expect(AppState().tray, isFalse);
    app.setTray(true);
    expect(_prefs()['tray'], isTrue);
    expect(AppState().tray, isTrue);
  });
}
