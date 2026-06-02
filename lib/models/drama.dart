import 'dart:convert';

// 将播放次数转换为万单位显示
String _formatPlayCount(String playCount) {
  if (playCount.isEmpty) return '';

  final count = int.tryParse(playCount);
  if (count == null) return playCount;

  if (count >= 10000) {
    final wan = (count / 10000).toStringAsFixed(1);
    return '$wan万热度';
  }

  return '$count热度';
}

class TagInfo {
  final String text;
  final List<String> bgColor;
  final List<String> darkBgColor;

  TagInfo({
    required this.text,
    required this.bgColor,
    required this.darkBgColor,
  });

  factory TagInfo.fromJson(Map<String, dynamic> json) {
    final bgColorList = <String>[];
    if (json['bg_color'] is List) {
      bgColorList.addAll((json['bg_color'] as List).map((e) => e.toString()));
    }

    final darkBgColorList = <String>[];
    if (json['dark_bg_color'] is List) {
      darkBgColorList.addAll(
        (json['dark_bg_color'] as List).map((e) => e.toString()),
      );
    }

    return TagInfo(
      text: json['text']?.toString() ?? '',
      bgColor: bgColorList,
      darkBgColor: darkBgColorList,
    );
  }
}

class SecondaryInfo {
  final String content;

  SecondaryInfo({required this.content});

  factory SecondaryInfo.fromJson(Map<String, dynamic> json) {
    return SecondaryInfo(content: json['content']?.toString() ?? '');
  }
}

class Drama {
  Drama({
    required this.id,
    required this.name,
    required this.actors,
    required this.cover,
    required this.intro,
    required this.tags,
    required this.status,
    required this.updateTime,
    this.recText,
    this.score,
    this.role,
    this.isTheaterResource = false,
    this.tagInfo,
    this.playCnt,
    this.secondaryInfoList,
    this.subTitle,
    this.pureCategoryTags,
    this.createTime,
  });

  final int id;
  final String name;
  final String actors;
  final String cover;
  final String intro;
  final List<String> tags;
  final String status;
  final String updateTime;
  final String? recText; // 热度
  final String? score; // 评分
  final String? role; // 角色
  final bool isTheaterResource; // 是否是剧场资源
  final TagInfo? tagInfo; // 标签信息
  final int? playCnt; // 播放次数
  final List<SecondaryInfo>? secondaryInfoList; // 收藏/点赞信息
  final String? subTitle; // 副标题
  final String? pureCategoryTags; // 纯分类标签
  final String? createTime; // 更新时间

  factory Drama.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    final parsedTags = <String>[];
    if (rawTags is List) {
      parsedTags.addAll(
        rawTags.map((tag) => tag.toString()).where((tag) => tag.isNotEmpty),
      );
    } else if (rawTags != null) {
      parsedTags.add(rawTags.toString());
    }
    return Drama(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      name: json['name']?.toString() ?? '',
      actors: json['actors']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      intro: json['intro']?.toString() ?? '',
      tags: parsedTags,
      status: json['status']?.toString() ?? '',
      updateTime: json['update_time']?.toString() ?? '',
    );
  }

  // 从剧场搜索接口返回的数据解析
  factory Drama.fromTheaterSearchJson(Map<String, dynamic> json) {
    // 获取video_detail中的详细信息
    final videoDetail = json['video_detail'] as Map<String, dynamic>? ?? {};

    // 解析series_id
    final seriesId = videoDetail['series_id'] is int
        ? videoDetail['series_id'] as int
        : int.tryParse(videoDetail['series_id']?.toString() ?? '') ?? 0;

    // 获取标题
    final title = json['title']?.toString() ??
        videoDetail['series_title']?.toString() ??
        '';

    // 获取封面
    final cover = json['cover']?.toString() ??
        videoDetail['series_cover']?.toString() ??
        '';

    // 获取简介
    final intro = videoDetail['series_intro']?.toString() ?? '';

    // 解析演员信息
    final actor = videoDetail['actor']?.toString() ?? '';

    // 解析角色信息
    final role = videoDetail['role']?.toString() ?? '';

    // 解析热度信息
    final recText = json['rec_text']?.toString() ?? '';

    // 解析播放次数
    final playCnt = json['play_cnt'] is int ? json['play_cnt'] as int : null;

    // 解析评分信息
    final score = json['score']?.toString() ?? '';

    // 解析tag_info（新剧/热播标签）
    TagInfo? tagInfo;
    if (json['tag_info'] is Map) {
      tagInfo = TagInfo.fromJson(
        (json['tag_info'] as Map).cast<String, dynamic>(),
      );
    }

    // 解析sub_title_list
    final secondaryInfoList = <SecondaryInfo>[];
    final subTitleList = json['sub_title_list'];
    if (subTitleList is List) {
      for (final item in subTitleList) {
        if (item is Map) {
          secondaryInfoList.add(
            SecondaryInfo.fromJson(item.cast<String, dynamic>()),
          );
        }
      }
    }

    // 解析标签 - 从category_schema中提取
    final parsedTags = <String>[];
    final categorySchemaStr = json['category_schema']?.toString() ??
        videoDetail['category_schema']?.toString() ??
        '';

    if (categorySchemaStr.isNotEmpty) {
      try {
        // category_schema是JSON字符串,需要解析
        final dynamic categorySchema = jsonDecode(categorySchemaStr);
        if (categorySchema is List) {
          for (final item in categorySchema) {
            if (item is Map && item['name'] != null) {
              final tagName = item['name'].toString().trim();
              if (tagName.isNotEmpty) {
                parsedTags.add(tagName);
              }
            }
          }
        }
      } catch (e) {
        // 如果解析失败,使用sub_title作为备用
        final subTitle = json['sub_title']?.toString() ?? '';
        if (subTitle.isNotEmpty) {
          final parts = subTitle.split('·');
          for (final part in parts) {
            final trimmed = part.trim();
            if (trimmed.isNotEmpty && !trimmed.startsWith('全')) {
              parsedTags.add(trimmed);
            }
          }
        }
      }
    }

    // 获取状态信息
    final status = videoDetail['series_status'] == 1 ? '已完结' : '连载中';

    // 获取集数信息
    final episodeCnt = json['episode_cnt']?.toString() ??
        videoDetail['episode_cnt']?.toString() ??
        '';
    final updateTime = episodeCnt.isNotEmpty ? '全$episodeCnt集' : '';

    // 解析副标题
    final subTitle = json['sub_title']?.toString() ?? '';

    return Drama(
      id: seriesId,
      name: title,
      actors: actor,
      cover: cover,
      intro: intro,
      tags: parsedTags,
      status: status,
      updateTime: updateTime,
      recText: recText.isNotEmpty ? recText : null,
      score: score.isNotEmpty ? score : null,
      role: role.isNotEmpty ? role : null,
      isTheaterResource: true,
      subTitle: subTitle.isNotEmpty ? subTitle : null,
      tagInfo: tagInfo,
      playCnt: playCnt,
      secondaryInfoList:
          secondaryInfoList.isNotEmpty ? secondaryInfoList : null,
    );
  }

  // 从剧场详情接口返回的数据解析
  factory Drama.fromTheaterDetailJson(Map<String, dynamic> json) {
    // 解析book_id
    final bookId = json['book_id'] is int
        ? json['book_id'] as int
        : int.tryParse(json['book_id']?.toString() ?? '') ?? 0;

    // 获取标题
    final title = json['book_name']?.toString() ?? '';

    // 获取封面
    final cover = json['thumb_url']?.toString() ?? '';

    // 获取简介
    final intro = json['abstract']?.toString() ?? '';

    // 解析主演信息 - 优先使用roles数组，否则使用role字符串
    String actor = '';
    final rolesArray = json['roles'];
    if (rolesArray is List && rolesArray.isNotEmpty) {
      actor = rolesArray.map((r) => r.toString()).join('、');
    } else {
      actor = json['role']?.toString() ?? '';
    }

    // 解析热度信息
    final recText = json['read_cnt_text']?.toString() ?? '';

    // 解析评分信息
    final score = json['score']?.toString() ?? '';

    // 解析标签 - 从tags字符串中split
    final parsedTags = <String>[];
    final tagsStr = json['tags']?.toString() ?? '';
    if (tagsStr.isNotEmpty) {
      final tagsList = tagsStr.split(',');
      for (final tag in tagsList) {
        final trimmed = tag.trim();
        if (trimmed.isNotEmpty) {
          parsedTags.add(trimmed);
        }
      }
    }

    // 获取状态信息 - status=2表示已完结
    final statusCode = json['status']?.toString() ?? '';
    final status = statusCode == '2' ? '已完结' : '连载中';

    // 获取集数信息
    final serialCount = json['serial_count']?.toString() ?? '';
    final updateTime = serialCount.isNotEmpty ? '全$serialCount集' : '';

    // 获取纯分类标签
    final pureCategoryTags = json['pure_category_tags']?.toString() ?? '';

    // 获取更新时间并格式化
    String createTime = '';
    final createTimeStr = json['create_time']?.toString() ?? '';
    if (createTimeStr.isNotEmpty) {
      try {
        final dateTime = DateTime.parse(createTimeStr);
        createTime =
            '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}:${dateTime.second.toString().padLeft(2, '0')}';
      } catch (e) {
        createTime = createTimeStr;
      }
    }

    return Drama(
      id: bookId,
      name: title,
      actors: actor,
      cover: cover,
      intro: intro,
      tags: parsedTags,
      status: status,
      updateTime: updateTime,
      recText: recText.isNotEmpty ? recText : null,
      score: score.isNotEmpty ? score : null,
      role: actor.isNotEmpty ? actor : null,
      isTheaterResource: true, // 标记为剧场资源
      pureCategoryTags: pureCategoryTags.isNotEmpty ? pureCategoryTags : null,
      createTime: createTime.isNotEmpty ? createTime : null,
    );
  }

  // 从首页/榜单接口返回的数据解析
  factory Drama.fromHomeJson(Map<String, dynamic> json) {
    // 解析series_id
    final seriesId = json['series_id'] is int
        ? json['series_id'] as int
        : int.tryParse(json['series_id']?.toString() ?? '') ?? 0;

    // 获取标题
    final title = json['title']?.toString() ?? '';

    // 获取封面
    final cover = json['cover']?.toString() ?? '';

    // 获取简介
    final intro = json['video_desc']?.toString() ?? '';

    // 解析评分信息
    final score = json['score']?.toString() ?? '';

    // 解析热度信息
    final recText = json['rec_text']?.toString() ?? '';

    // 解析副标题
    final subTitle = json['sub_title']?.toString() ?? '';

    // 解析标签 - 从categories数组中提取
    final parsedTags = <String>[];
    final categories = json['categories'];
    if (categories is List) {
      for (final category in categories) {
        final tagName = category.toString().trim();
        if (tagName.isNotEmpty) {
          parsedTags.add(tagName);
        }
      }
    }

    // 获取集数信息
    final episodeCnt = json['episode_cnt']?.toString() ?? '';
    final updateTime = episodeCnt.isNotEmpty ? '全$episodeCnt集' : '';

    // 获取播放次数
    final playCntStr = json['play_cnt']?.toString() ?? '';
    final playCntInt = int.tryParse(playCntStr);

    // 解析tag_info
    TagInfo? tagInfo;
    if (json['tag_info'] != null && json['tag_info'] is Map) {
      tagInfo = TagInfo.fromJson(json['tag_info'] as Map<String, dynamic>);
    }

    // 解析secondary_info_list
    List<SecondaryInfo>? secondaryInfoList;
    if (json['secondary_info_list'] is List) {
      secondaryInfoList = (json['secondary_info_list'] as List)
          .map((item) => SecondaryInfo.fromJson(item as Map<String, dynamic>))
          .toList();
    }

    return Drama(
      id: seriesId,
      name: title,
      actors: '', // 首页接口不返回演员信息
      cover: cover,
      intro: intro,
      tags: parsedTags,
      status: '', // 首页接口不返回状态
      updateTime: updateTime,
      recText: recText.isNotEmpty
          ? recText
          : (playCntStr.isNotEmpty ? _formatPlayCount(playCntStr) : null),
      score: score.isNotEmpty ? score : null,
      role: null,
      isTheaterResource: true, // 标记为剧场资源
      tagInfo: tagInfo,
      playCnt: playCntInt,
      secondaryInfoList: secondaryInfoList,
      subTitle: subTitle.isNotEmpty ? subTitle : null,
    );
  }
}
