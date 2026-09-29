import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ah_developer_kiryana_store/sync/branch_config_store.dart';
import 'package:ah_developer_kiryana_store/sync/cloud_config_store.dart';
import 'package:ah_developer_kiryana_store/sync/device_tag.dart';
import 'package:ah_developer_kiryana_store/sync/network_monitor.dart';

/// Phase 10 (chhoti files): DeviceTag, BranchConfigStore, CloudConfigStore, NetworkMonitor.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NetworkMonitor.resetForTest();
  });

  group('DeviceTag', () {
    test('4 akhsar UPPERCASE, pehli baar ban kar mehfooz, dobara wohi', () async {
      await DeviceTag.init();
      final first = DeviceTag.current;
      expect(first, matches(RegExp(r'^[0-9A-F]{4}$')));
      await DeviceTag.init();
      expect(DeviceTag.current, first);
      final p = await SharedPreferences.getInstance();
      expect(p.getString(DeviceTag.prefsKey), first);
    });

    test('pehle se mehfooz tag wapas milta hai', () async {
      SharedPreferences.setMockInitialValues({DeviceTag.prefsKey: 'AB12'});
      await DeviceTag.init();
      expect(DeviceTag.current, 'AB12');
    });
  });

  group('BranchConfigStore', () {
    test('isValid: 2-50, sirf A-Z a-z 0-9 _ -', () {
      expect(BranchConfigStore.isValid('MAIN'), isTrue);
      expect(BranchConfigStore.isValid(' br-1_a '), isTrue);
      expect(BranchConfigStore.isValid('A'), isFalse);
      expect(BranchConfigStore.isValid('a/b'), isFalse);
      expect(BranchConfigStore.isValid('a b'), isFalse);
      expect(BranchConfigStore.isValid('x' * 51), isFalse);
      expect(BranchConfigStore.isValid(''), isFalse);
    });

    test('set/init/clear; ghalat code par ArgumentError', () async {
      await BranchConfigStore.clear();
      expect(BranchConfigStore.isConfigured(), isFalse);
      expect(BranchConfigStore.current, '');
      expect(() => BranchConfigStore.set('a/b'), throwsArgumentError);
      await BranchConfigStore.set('  SHOP-1 ');
      expect(BranchConfigStore.current, 'SHOP-1');
      expect(BranchConfigStore.isConfigured(), isTrue);
      // "app restart": cache khali karke init
      await BranchConfigStore.clear();
      SharedPreferences.setMockInitialValues({BranchConfigStore.keyBranchId: 'SHOP-1'});
      await BranchConfigStore.init();
      expect(BranchConfigStore.current, 'SHOP-1');
      SharedPreferences.setMockInitialValues({BranchConfigStore.keyBranchId: 'bad/id'});
      await BranchConfigStore.init();
      expect(BranchConfigStore.current, '');
    });
  });

  group('CloudConfigStore', () {
    test('save trim karta hai; get; isConfigured; clear', () async {
      expect(await CloudConfigStore.get(), isNull);
      expect(await CloudConfigStore.isConfigured(), isFalse);
      await CloudConfigStore.save(const CloudConfig(
          projectId: ' proj ', apiKey: ' key ', appId: ' 1:2:android:3 ', storageBucket: ' b '));
      final c = await CloudConfigStore.get();
      expect(
          c,
          const CloudConfig(
              projectId: 'proj', apiKey: 'key', appId: '1:2:android:3', storageBucket: 'b'));
      expect(await CloudConfigStore.isConfigured(), isTrue);
      await CloudConfigStore.clear();
      expect(await CloudConfigStore.get(), isNull);
    });

    test('toOptions: khali storageBucket = null', () {
      final o = CloudConfigStore.toOptions(
          const CloudConfig(projectId: 'p', apiKey: 'k', appId: 'a'));
      expect(o.projectId, 'p');
      expect(o.apiKey, 'k');
      expect(o.appId, 'a');
      expect(o.storageBucket, isNull);
    });
  });

  group('NetworkMonitor debounce', () {
    test('20 s ke andar ki burst = sirf ek trigger', () {
      var t = 1000000;
      NetworkMonitor.nowMs = () => t;
      var fired = 0;
      NetworkMonitor.onOnline = () => fired++;
      expect(NetworkMonitor.onNetworkAvailable(), isTrue);
      t += 5000;
      expect(NetworkMonitor.onNetworkAvailable(), isFalse);
      t += 14999;
      expect(NetworkMonitor.onNetworkAvailable(), isFalse);
      t += 1;
      expect(NetworkMonitor.onNetworkAvailable(), isTrue);
      expect(fired, 2);
    });
  });
}
