import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  static const supabaseUrl = 'https://czfvqhepsqkgsrfnknwm.supabase.co';
  static const supabaseAnonKey = 'sb_publishable_1FmX_1hjAAUesXFYOzwa6g_mpf7jTWr';

  static SupabaseClient get client => Supabase.instance.client;
}
