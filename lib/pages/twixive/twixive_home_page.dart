import 'package:flutter/material.dart';

import '../../models/twixive.dart';
import '../../services/api_client.dart';
import 'twixive_list.dart';

class TwixiveHomePage extends StatelessWidget {
  const TwixiveHomePage({super.key, required this.apiClient});

  final ApiClient apiClient;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
      child: ColoredBox(
        color: Colors.white,
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: EdgeInsets.symmetric(horizontal: 8),
                labelPadding: EdgeInsets.symmetric(horizontal: 16),
                indicatorSize: TabBarIndicatorSize.label,
                indicatorColor: Color(0xFFFF2442),
                labelColor: Color(0xFF20232B),
                unselectedLabelColor: Color(0xFF8B8F98),
                labelStyle:
                    TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                unselectedLabelStyle:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
                dividerColor: Color(0xFFF0F1F4),
                tabs: [
                  Tab(text: '首页'),
                  Tab(text: '新剧'),
                  Tab(text: '排行榜'),
                  Tab(text: '趋势'),
                  Tab(text: '用户'),
                  Tab(text: '喜欢')
                ],
              ),
              Expanded(
                  child: TabBarView(children: [
                TwixiveList(apiClient: apiClient, feed: TwixiveFeed.home),
                TwixiveList(apiClient: apiClient, feed: TwixiveFeed.latest),
                TwixiveList(apiClient: apiClient, feed: TwixiveFeed.ranking),
                TwixiveList(apiClient: apiClient, feed: TwixiveFeed.trending),
                TwixiveList(apiClient: apiClient, feed: TwixiveFeed.users),
                TwixiveList(apiClient: apiClient, likedOnly: true),
              ])),
            ],
          ),
        ),
      ),
    );
  }
}

class TwixiveUserPage extends StatelessWidget {
  const TwixiveUserPage(
      {super.key, required this.apiClient, required this.user});

  final ApiClient apiClient;
  final TwixiveUser user;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
            title: Text(user.label),
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent),
        body: TwixiveList(apiClient: apiClient, user: user),
      );
}
