import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/sync/cloud_config_store.dart';

void main() {
  const sample = '''
{
  "project_info": {
    "project_number": "1",
    "project_id": "my-proj",
    "storage_bucket": "my-proj.firebasestorage.app"
  },
  "client": [
    {
      "client_info": {
        "mobilesdk_app_id": "1:1:android:abc",
        "android_client_info": {"package_name": "com.example.app"}
      },
      "api_key": [{"current_key": "AIzaKEY"}]
    }
  ],
  "configuration_version": "1"
}
''';

  test('google-services.json se 4 values nikalti hain', () {
    final c = parseGoogleServicesJson(sample)!;
    expect(c.projectId, 'my-proj');
    expect(c.apiKey, 'AIzaKEY');
    expect(c.appId, '1:1:android:abc');
    expect(c.storageBucket, 'my-proj.firebasestorage.app');
  });

  test('ghalat / khali / adhoora => null', () {
    expect(parseGoogleServicesJson(''), isNull);
    expect(parseGoogleServicesJson('not json'), isNull);
    expect(parseGoogleServicesJson('{"project_info": {}}'), isNull);
    expect(parseGoogleServicesJson('{"project_info": {"project_id": "p"}, "client": []}'), isNull);
    expect(parseGoogleServicesJson('[1,2]'), isNull);
  });

  test('App ID se messagingSenderId (project number) nikalta hai', () {
    expect(CloudConfigStore.senderIdFromAppId('1:675436217091:android:72f9477cce20fdb098df36'), '675436217091');
    expect(CloudConfigStore.senderIdFromAppId(' 1:42:web:abc '), '42');
    expect(CloudConfigStore.senderIdFromAppId('a'), '');
    expect(CloudConfigStore.senderIdFromAppId(''), '');
  });
}
