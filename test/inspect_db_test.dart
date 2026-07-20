import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Inspect Access Records Columns', () async {
    final client = SupabaseClient(
      'https://uajfwuwgbnpptvkujvwp.supabase.co',
      'sb_publishable__k-MtHWCMbpsCzek22ZVuQ_OOmr3P8j',
    );
    
    try {
      final res = await client.from('access_records').select().limit(1);
      print('Columns of access_records:');
      if (res.isNotEmpty) {
        print(res.first.keys.toList());
      } else {
        print('No records found, table is empty.');
      }
    } catch (e) {
      print('Error querying access_records: $e');
    }

    try {
      final res = await client.from('pre_auth_records').select().limit(1);
      print('Columns of pre_auth_records:');
      if (res.isNotEmpty) {
        print(res.first.keys.toList());
      } else {
        print('No records found, table is empty.');
      }
    } catch (e) {
      print('Error querying pre_auth_records: $e');
    }

    try {
      final res = await client.from('blacklist_entries').select().limit(1);
      print('Columns of blacklist_entries:');
      if (res.isNotEmpty) {
        print(res.first.keys.toList());
      } else {
        print('No records found, table is empty.');
      }
    } catch (e) {
      print('Error querying blacklist_entries: $e');
    }

    try {
      final res = await client.from('installations').select().limit(1);
      print('Columns of installations:');
      if (res.isNotEmpty) {
        print(res.first.keys.toList());
      } else {
        print('No records found, table is empty.');
      }
    } catch (e) {
      print('Error querying installations: $e');
    }

    try {
      final res = await client.from('settings').select().limit(1);
      print('Columns of settings:');
      if (res.isNotEmpty) {
        print(res.first.keys.toList());
      } else {
        print('No records found, table is empty.');
      }
    } catch (e) {
      print('Error querying settings: $e');
    }

    try {
      final res = await client.from('app_config').select().limit(1);
      print('Columns of app_config:');
      if (res.isNotEmpty) {
        print(res.first.keys.toList());
      } else {
        print('No records found, table is empty.');
      }
    } catch (e) {
      print('Error querying app_config: $e');
    }
  });
}
