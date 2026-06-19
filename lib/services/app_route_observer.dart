import 'package:flutter/widgets.dart';

/// 全局路由观察者。注册到 MaterialApp.navigatorObservers，供页面（如 PlayerPage）
/// 通过 RouteAware 感知“被新页覆盖 / 新页弹出后回到自己”，从而暂停/恢复播放，
/// 避免在已有播放页之上再打开播放页时两路音频叠加。
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
