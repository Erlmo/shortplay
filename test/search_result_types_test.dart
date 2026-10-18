import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/models/search_results.dart';

Map<String, dynamic> video(String id, [String? title]) => {
      'series_id': id,
      'title': title ?? '作品$id',
      'cover': 'https://example.invalid/$id.jpg',
      'video_detail': {'series_id': id},
    };

Map<String, dynamic> playable(String id, [String? title]) => {
      'video_data': [video(id, title)],
    };

Map<String, dynamic> reservable(String id, [String? title]) => {
      'subscribe_items': [
        {'item_id_str': id, 'name': title ?? '待播$id', 'schema': 'dragon://$id'},
      ],
    };

Map<String, dynamic> seriesCell({
  String id = '101',
  List<Map<String, dynamic>>? items,
}) =>
    {
      'show_type': 551,
      'search_ip_card_content_type': 24,
      'video_data': [video(id)],
      'cell_data': items ?? [playable('101'), playable('102')],
    };

void main() {
  for (final type in [369, 412, 420, 476]) {
    test('普通$type只取首个视频，不把附属数据变成关联季', () {
      final cell = {
        'show_type': type,
        'cell_name': '普通卡',
        'video_data': [video('101'), video('102')],
        'cell_data': [seriesCell()],
        'section_data': [playable('103')],
        'lynx_data': {
          'video_data': [video('104')]
        },
        'unknown_meta': {'keep': true},
      };
      final group = SearchResultGroup.fromJson(cell);
      expect(group.entries.map((drama) => drama.id), [101]);
      expect(group.seriesAlbums, isEmpty);
      expect(group.raw, cell);
      expect(group.title, '普通卡');
    });
  }

  test('普通卡首项无效不跳过取第二项，顶层合法ID可作详情ID回退', () {
    final invalidFirst = SearchResultGroup.fromJson({
      'show_type': 369,
      'video_data': [{}, video('102')],
    });
    expect(invalidFirst.entries, isEmpty);
    final topLevel = SearchResultGroup.fromJson({
      'show_type': 369,
      'video_data': [
        {
          'series_id': '7621200213801176126',
          'video_detail': <String, dynamic>{}
        },
      ],
    });
    expect(topLevel.entries.single.id, 7621200213801176126);
  });

  for (final type in [0, 531, 572, 612, 655, 656, 657, 658, 999]) {
    test('未还原或非普通$type完整保留raw，不猜字段生成剧集或季', () {
      final cell = {
        'show_type': type,
        'video_data': [video('101'), video('102')],
        'post_data': [
          {'post_id': '109', 'content': '正文'}
        ],
        'cell_data': [seriesCell()],
        'lynx_data': {
          'cell_data': [seriesCell()]
        },
      };
      final group = SearchResultGroup.fromJson(cell);
      expect(group.showType, type);
      expect(group.raw, cell);
      expect(group.entries, isEmpty);
      expect(group.seriesAlbums, isEmpty);
    });
  }

  test('Lynx卡即使包含已知普通或系列数据也不扁平化', () {
    for (final cell in [
      {
        'show_type': 369,
        'video_data': [video('101')]
      },
      seriesCell(),
      {
        'show_type': 601,
        'cell_data': [
          {
            'show_type': 550,
            'cell_data': [seriesCell()]
          },
        ],
      },
    ]) {
      cell['render_cell_type'] = 1;
      final group = SearchResultGroup.fromJson(cell);
      expect(group.renderType, 1);
      expect(group.entries, isEmpty);
      expect(group.seriesAlbums, isEmpty);
      expect(group.raw, cell);
    }
  });

  test('551且内容类型24才构成系列卡，不能从普通视频或同IP猜测', () {
    final valid = SearchResultGroup.fromJson(seriesCell());
    expect(valid.entries, isEmpty);
    expect(valid.seriesAlbums.single.preview.id, 101);
    expect(
        valid.seriesAlbums.single.items.map((item) => item.id), ['101', '102']);
    for (final patch in [
      {'show_type': 369},
      {'search_ip_card_content_type': 3},
      {'search_ip_card_content_type': null},
    ]) {
      expect(SearchSeriesAlbum.fromCell({...seriesCell(), ...patch}), isNull);
    }
  });

  test('IP根卡仅沿549或601到550模块到551系列的白名单路径解析', () {
    for (final root in [549, 601]) {
      final group = SearchResultGroup.fromJson({
        'show_type': root,
        'video_data': [video('999')],
        'cell_data': [
          {
            'show_type': 550,
            'cell_name': '本剧其他季',
            'cell_data': [seriesCell()],
          },
          seriesCell(id: '888'), // 缺少550模块，不能提升。
          {
            'show_type': 612,
            'cell_data': [seriesCell(id: '777')],
          },
          {
            'show_type': 550,
            'render_cell_type': 1,
            'cell_data': [seriesCell(id: '666')],
          },
          {
            'show_type': 550,
            'cell_data': [
              {
                'show_type': 369,
                'video_data': [video('555')]
              },
            ],
          },
        ],
      });
      expect(group.entries, isEmpty);
      expect(group.seriesAlbums, hasLength(1));
      expect(group.seriesAlbums.single.moduleTitle, '本剧其他季');
      expect(group.seriesAlbums.single.preview.id, 101);
    }
  });

  test('多个明确模块分别保留，不能把其他模块压平成同一系列', () {
    final group = SearchResultGroup.fromJson({
      'show_type': 601,
      'cell_data': [
        for (var n = 1; n <= 2; n++)
          {
            'show_type': 550,
            'cell_name': '模块$n',
            'cell_data': [seriesCell(id: '${n}01')],
          },
      ],
    });
    expect(
        group.seriesAlbums.map((album) => album.moduleTitle), ['模块1', '模块2']);
    expect(group.seriesAlbums.map((album) => album.preview.id), [101, 201]);
  });

  test('系列预览严格使用首个顶层series_id，空预览或空有效列表拒绝', () {
    for (final patch in [
      {'video_data': []},
      {
        'video_data': [{}, video('101')]
      },
      {
        'video_data': [
          {
            'video_detail': {'series_id': '101'}
          },
        ],
      },
      {'cell_data': []},
      {
        'cell_data': [<String, dynamic>{}]
      },
      {'cell_data': 'invalid'},
    ]) {
      expect(SearchSeriesAlbum.fromCell({...seriesCell(), ...patch}), isNull);
    }
  });

  test('系列预览使用album_info标题封面集数回退，不猜其他字段', () {
    final album = SearchSeriesAlbum.fromCell({
      ...seriesCell(),
      'video_data': [
        {
          'series_id': '101',
          'title': '',
          'cover': '',
          'episode_cnt': 1,
          'album_info': {
            'title': '正式系列预览',
            'small_cover': 'https://example.invalid/small',
            'cover': 'https://example.invalid/large',
            'episode_total_cnt': 80,
          },
        },
      ],
    })!;
    expect(album.preview.name, '正式系列预览');
    expect(album.preview.cover, 'https://example.invalid/small');
    expect(album.preview.updateTime, '全80集');
    final large = SearchSeriesAlbum.fromCell({
      ...seriesCell(),
      'video_data': [
        {
          'series_id': '101',
          'cover': '',
          'album_info': {
            'small_cover': '',
            'cover': 'https://example.invalid/large'
          },
        },
      ],
    })!;
    expect(large.preview.cover, 'https://example.invalid/large');
  });

  test('有效预约项计入总季数，稳定类型ID去重并保留接口顺序', () {
    final album = SearchSeriesAlbum.fromCell(seriesCell(items: [
      playable('101'),
      reservable('101'), // 相同字面ID但不同原生类型，应分别保留。
      playable('102'),
      playable('101'),
      reservable('101'),
      reservable('103'),
    ]))!;
    expect(album.items.map((item) => item.key), [
      'playable:101',
      'reservable:101',
      'playable:102',
      'reservable:103',
    ]);
    expect(album.items, hasLength(4));
    expect(album.items[0].drama?.id, 101);
    expect(album.items[1].isPlayable, isFalse);
    expect(album.items[1].drama, isNull);
  });

  test('同一子项可播和预约ID冲突丢弃，不选择其中一种也不污染其他项', () {
    final album = SearchSeriesAlbum.fromCell(seriesCell(items: [
      {...playable('104'), ...reservable('105')},
      {...playable('106'), ...reservable('106')},
      playable('101'),
      reservable('102'),
    ]))!;
    expect(album.items.map((item) => item.id), ['101', '102']);
  });

  test('预约ID优先item_id_str，空白时回退正数item_id，并保留64位精度', () {
    final album = SearchSeriesAlbum.fromCell(seriesCell(items: [
      {
        'subscribe_items': [
          {'item_id_str': 'future-id', 'item_id': 2}
        ],
      },
      {
        'subscribe_items': [
          {'item_id_str': ' ', 'item_id': 7621200213801176126}
        ],
      },
      {
        'subscribe_items': [
          {'item_id': 0}
        ],
      },
      {
        'subscribe_items': [
          {'item_id': -1}
        ],
      },
    ]))!;
    expect(album.items.map((item) => item.id),
        ['future-id', '7621200213801176126']);
    expect(album.items.every((item) => !item.isPlayable && item.drama == null),
        isTrue);
  });

  test('条目只读取各自首个视频或预约，不能从后续值捞出可播ID', () {
    final album = SearchSeriesAlbum.fromCell(seriesCell(items: [
      {
        'video_data': [{}, video('104')]
      },
      {
        'subscribe_items': [
          {},
          {'item_id': 105}
        ]
      },
      playable('101'),
    ]))!;
    expect(album.items.map((item) => item.id), ['101']);
  });

  test('条目标题封面与预约路由使用已核实的原生字段回退链', () {
    final album = SearchSeriesAlbum.fromCell(seriesCell(items: [
      {
        'cell_name': '可播回退名称',
        'cell_picture_url': 'https://example.invalid/playable',
        'video_data': [
          {
            'series_id': '101',
            'title': '',
            'cover': '',
            'url': 'dragon://play/101'
          },
        ],
      },
      {
        'cell_name': '预约回退名称',
        'cell_picture_url': 'https://example.invalid/reservation',
        'cell_url': 'dragon://cell',
        'subscribe_items': [
          {'item_id': 102, 'schema': '', 'detail_schema': 'dragon://detail'},
        ],
      },
      {
        'cell_url': 'dragon://cell-only',
        'subscribe_items': [
          {'item_id': 103}
        ],
      },
      {
        'cell_url': 'dragon://ignored-cell',
        'subscribe_items': [
          {
            'item_id': 104,
            'schema': 'dragon://preferred',
            'detail_schema': 'dragon://ignored-detail'
          }
        ],
      },
    ]))!;
    expect(album.items[0].title, '可播回退名称');
    expect(album.items[0].cover, 'https://example.invalid/playable');
    expect(album.items[0].drama?.name, '可播回退名称');
    expect(album.items[0].routeUrl, 'dragon://play/101');
    expect(album.items[1].title, '预约回退名称');
    expect(album.items[1].routeUrl, 'dragon://detail');
    expect(album.items[2].routeUrl, 'dragon://cell-only');
    expect(album.items[3].routeUrl, 'dragon://preferred');
  });

  test('系列保留全部有效条目，不按首屏数量截断或仅保留可播项', () {
    final album = SearchSeriesAlbum.fromCell(seriesCell(items: [
      for (var n = 1; n <= 15; n++) playable('$n'),
      reservable('16'),
    ]))!;
    expect(album.items, hasLength(16));
    expect(album.items.last.isPlayable, isFalse);
    expect(() => album.items.clear(), throwsUnsupportedError);
  });
}
