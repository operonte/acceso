import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  print('Initializing Supabase...');
  await Supabase.initialize(
    url: 'https://uajfwuwgbnpptvkujvwp.supabase.co',
    publishableKey: 'sb_publishable__k-MtHWCMbpsCzek22ZVuQ_OOmr3P8j',
  );
  
  final client = Supabase.instance.client;
  print('Supabase initialized. Testing queries...');

  final tablesToTest = ['installations', 'groups', 'grupo', 'instalaciones', 'instalacion', 'tenants'];
  for (var table in tablesToTest) {
    try {
      final res = await client.from(table).select().limit(1);
      print('Table "$table" exists! Result: $res');
    } catch (e) {
      print('Table "$table" does not exist or error: $e');
    }
  }
}
