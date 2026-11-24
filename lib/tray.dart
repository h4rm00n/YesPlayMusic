// 托盘：常驻图标 + 菜单；开着时关窗只是隐藏窗口，音乐继续放。
//
// Linux 走 tray_manager 的 StatusNotifierItem（D-Bus 直连，不需要系统装
// appindicator 库）。KDE 直接可见；GNOME 要装 AppIndicator 扩展（设置里有提示）。
// 面板不回传图标点击事件（菜单由面板自己弹出），所以「显示主窗口」是菜单项；
// 菜单项的点击事件发在 MenuItem 自己身上（nativeapi 的设计），要逐项挂监听。
//
// 隐藏后第一次恢复时，Flutter 视图要等窗口尺寸变化才重绘：GTK 把窗口藏起来时
// 会解除视图的 map，恢复后引擎不会自己再收到一次尺寸/绘制请求。所以恢复后替
// 用户做一次 1px 的尺寸变化再改回来（见 _nudgeSize），不然窗口是空的、拖着
// 改一下尺寸才出内容。只影响恢复这一下，之后正常。
//
// macOS、Windows 还没接：attach 直接返回，设置里的开关也只在 Linux 显示。
// 已知限制：窗口隐藏后再启动会是第二个进程（runner 声明了 G_APPLICATION_NON_UNIQUE）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show Size, WidgetsBinding;
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart' as win;

import 'l10n/l10n.dart';
import 'state.dart';

class Tray {
  Tray(this.app);

  final AppState app;

  win.Window? _window;
  tray.TrayIcon? _icon;
  tray.Menu? _menu;
  tray.MenuItem? _show, _play, _prev, _next, _quit;
  win.ListenerId? _closeListener;
  bool? _playing;
  String _lang = '';
  String _tip = '';

  /// 置位后不再拦 close（菜单「退出」走真退出）。
  bool _quitting = false;

  void attach() {
    if (!Platform.isLinux) return;
    _window = win.WindowManager.instance.getCurrent();
    if (_window == null) return;
    _closeListener = _window!.addListener(_onWindowEvent);
    app.addListener(_sync);
    _sync();
  }

  void detach() {
    if (!Platform.isLinux) return;
    final listener = _closeListener;
    if (listener != null) _window?.removeListener(listener);
    app.removeListener(_sync);
    _teardown();
  }

  /// 关窗请求：托盘开着就取消、隐藏到托盘；否则放行（和从前一样关窗退出）。
  FutureOr<void> _onWindowEvent(win.WindowEvent event) async {
    if (event is! win.WindowCloseRequestedEvent) return;
    if (_quitting || !app.tray) return;
    event.request.cancel();
    _window?.hide();
  }

  void _showIcon() {
    if (_icon != null) return;
    final icon = tray.TrayIcon.create();
    final menu = tray.Menu.create();
    if (icon == null || menu == null) return;
    icon.icon = tray.ImageAsset.fromAsset('assets/tray/icon.png');
    icon.setTooltip('YesPlayMusic');
    _menu = menu;
    _fillMenu();
    // 不设触发器面板就拿不到菜单（Menu 属性指向 /NO_DBUSMENU）。Linux 面板
    // 不回传图标点击事件，左右键都交给面板弹菜单最顺。
    icon.setContextMenuTrigger(tray.ContextMenuTrigger.clicked);
    icon.setContextMenu(menu);
    _icon = icon;
  }

  void _fillMenu() {
    final menu = _menu!;
    _show = _item(L.trayShowWindow, _showWindow);
    _play = _item(app.playing ? L.actionPause : L.actionPlay, app.togglePlay);
    _prev = _item(L.actionPrev, app.prev);
    _next = _item(L.actionNext, app.next);
    _quit = _item(L.trayQuit, _quitApp);
    for (final i in [_show, _play]) {
      menu.addItem(i);
    }
    menu.addSeparator();
    for (final i in [_prev, _next]) {
      menu.addItem(i);
    }
    menu.addSeparator();
    menu.addItem(_quit);
    _playing = app.playing;
    _lang = app.lang;
  }

  /// 点击事件发在 MenuItem 自己身上，所以在每项上挂监听。
  tray.MenuItem? _item(String label, void Function() onTap) {
    final item = tray.MenuItem.createWithLabelAndType(
      label,
      tray.MenuItemType.normal,
    );
    if (item == null) return null;
    item.addListener((event) {
      if (event is tray.MenuItemClickedEvent) onTap();
    });
    return item;
  }

  void _showWindow() {
    final w = _window;
    if (w == null) return;
    w.show();
    w.focus();
    // 隐藏期间 GTK 把窗口解除映射，恢复后引擎不会自己再画一帧，窗口是空的、
    // 拖一下尺寸才出内容。这里替用户做一次真实的尺寸变化再改回来，见文件头。
    _nudgeSize();
  }

  /// 恢复窗口后把高度改 1px 再改回来，逼 GTK 重新分配、重绘。
  ///
  /// 换完还要再催一帧：尺寸事件到达引擎后由新的帧把内容画上去。
  Future<void> _nudgeSize() async {
    final w = _window;
    if (w == null) return;
    final s = w.size.toSize();
    final bumped = Size(s.width, s.height + 1).toNative();
    w.setSize(bumped, false);
    WidgetsBinding.instance.scheduleForcedFrame();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    if (!identical(_window, w)) return;
    w.setSize(s.toNative(), false);
    WidgetsBinding.instance.scheduleForcedFrame();
  }

  /// 菜单里的「退出」要真退出：不再拦 close，撤掉托盘再关窗。
  void _quitApp() {
    _quitting = true;
    _teardown();
    _window?.close();
  }

  /// 跟上应用状态：开关决定托盘在不在，播放状态和语言决定菜单文案。
  void _sync() {
    if (app.tray) {
      _showIcon();
    } else {
      _teardown();
      return;
    }
    if (_play != null && (_playing != app.playing || _lang != app.lang)) {
      if (_lang != app.lang) {
        _show?.label = L.trayShowWindow;
        _prev?.label = L.actionPrev;
        _next?.label = L.actionNext;
        _quit?.label = L.trayQuit;
      }
      _play?.label = app.playing ? L.actionPause : L.actionPlay;
      _playing = app.playing;
      _lang = app.lang;
    }
    // 悬停提示跟随当前歌；没在放歌就只留应用名
    final t = app.queue.isEmpty ? null : app.track;
    final artist = t?.artist ?? '';
    final tip = t == null
        ? 'YesPlayMusic'
        : artist.isEmpty
        ? t.title
        : '${t.title} · $artist';
    if (tip != _tip) {
      _tip = tip;
      _icon?.setTooltip(tip);
    }
  }

  void _teardown() {
    for (final i in [_show, _play, _prev, _next, _quit]) {
      i?.dispose();
    }
    _show = _play = _prev = _next = _quit = null;
    _menu?.dispose();
    _menu = null;
    _icon?.dispose();
    _icon = null;
    _playing = null;
    _tip = '';
  }
}
