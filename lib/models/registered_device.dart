/// 一次安装注册得到的请求身份，与设备的真实硬件标识无关。
class RegisteredDevice {
  /// 与服务端现有公共设备一致，仅用于首次注册失败后的读取兜底。
  /// 不得保存成安装身份，也不得用于观看记录写入。
  static const defaultDevice = RegisteredDevice._(
    deviceId: '4140076827415936',
    installId: '4140076827420032',
    cdid: '91c076bb-b3c0-41b7-af53-0be4ee506b90',
    deviceBrand: 'HONOR',
    deviceModel: '6XE-GVVA',
    osVersion: '12',
  );

  const RegisteredDevice._({
    required this.deviceId,
    required this.installId,
    required this.cdid,
    required this.deviceBrand,
    required this.deviceModel,
    required this.osVersion,
  });

  factory RegisteredDevice.fromJson(Map<String, dynamic> json) {
    return RegisteredDevice._(
      deviceId: _read(json, 'device_id', _identifier),
      installId: _read(json, 'install_id', _identifier),
      cdid: _read(json, 'cdid', _uuid),
      deviceBrand: _read(json, 'device_brand', _deviceText),
      deviceModel: _read(json, 'device_model', _deviceText),
      osVersion: _read(json, 'os_version', _osVersion, maxLength: 16),
    );
  }

  final String deviceId;
  final String installId;
  final String cdid;
  final String deviceBrand;
  final String deviceModel;
  final String osVersion;

  static final RegExp _identifier = RegExp(r'^[1-9][0-9]{0,31}$');
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final RegExp _deviceText = RegExp(r'^[A-Za-z0-9 _+().-]{1,64}$');
  static final RegExp _osVersion = RegExp(r'^[0-9]+(?:\.[0-9]+)*$');

  Map<String, String> toJson() => {
        'device_id': deviceId,
        'install_id': installId,
        'cdid': cdid,
        'device_brand': deviceBrand,
        'device_model': deviceModel,
        'os_version': osVersion,
      };

  static String _read(
    Map<String, dynamic> json,
    String key,
    RegExp pattern, {
    int? maxLength,
  }) {
    final value = json[key];
    if (value is! String ||
        value.trim().isEmpty ||
        (maxLength != null && value.length > maxLength)) {
      throw FormatException('设备信息字段无效: $key');
    }
    final match = pattern.firstMatch(value);
    if (match == null || match.start != 0 || match.end != value.length) {
      throw FormatException('设备信息字段无效: $key');
    }
    return value;
  }
}
