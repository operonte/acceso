import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/colors.dart';

enum UserRole { admin, guardia, cliente }

class LoginSession {
  final UserRole role;
  final String? installationName;

  LoginSession({required this.role, this.installationName});
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _passwordController = TextEditingController();
  bool _obscureText = true;
  String? _errorMessage;
  bool _isLoading = false;

  void _handleLogin() async {
    final password = _passwordController.text.trim();
    if (password.isEmpty) {
      setState(() {
        _errorMessage = 'Por favor, ingresa tu clave de acceso';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final client = Supabase.instance.client;
      // 1. Query the app_credentials table in Supabase
      final response = await client
          .from('app_credentials')
          .select()
          .eq('key_hash', password)
          .limit(1);

      if (response.isNotEmpty) {
        final Map<String, dynamic> cred = response.first;
        final roleStr = cred['role'] as String;
        final instName = cred['installation_name'] as String?;

        UserRole role;
        if (roleStr == 'admin') {
          role = UserRole.admin;
        } else if (roleStr == 'guardia') {
          role = UserRole.guardia;
        } else {
          role = UserRole.cliente;
        }

        // Cache locally for offline support
        final installationsBox = Hive.box('installations_box');
        if (role == UserRole.admin) {
          await installationsBox.put('_admin_cached_key', password);
        } else if (instName != null) {
          // Fetch both guard and client keys for this installation to fully provision the local cache
          final allInstCreds = await client
              .from('app_credentials')
              .select()
              .eq('installation_name', instName);
          
          String? guardKey;
          String? clientKey;
          for (var c in allInstCreds) {
            if (c['role'] == 'guardia') {
              guardKey = c['key_hash'];
            } else if (c['role'] == 'cliente') {
              clientKey = c['key_hash'];
            }
          }
          await installationsBox.put(instName, {
            'name': instName,
            'guardKey': guardKey ?? '',
            'clientKey': clientKey ?? '',
          });
        }

        setState(() {
          _isLoading = false;
        });

        if (mounted) {
          Navigator.pushReplacementNamed(
            context,
            '/dashboard',
            arguments: LoginSession(
              role: role,
              installationName: instName,
            ),
          );
        }
        return;
      } else {
        throw Exception('Clave no registrada en el servidor.');
      }
    } catch (e) {
      debugPrint('Database authentication failed, trying offline cache: $e');
      
      // 2. Offline Fallback from local Hive box
      final installationsBox = Hive.box('installations_box');
      
      // Check cached admin key
      final cachedAdminKey = installationsBox.get('_admin_cached_key') as String?;
      // Safe default key if database has never been connected yet (First run)
      final adminPassword = cachedAdminKey ?? 'Operonte23#';

      if (password == adminPassword) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
        if (mounted) {
          Navigator.pushReplacementNamed(
            context,
            '/dashboard',
            arguments: LoginSession(role: UserRole.admin),
          );
        }
        return;
      }

      // Check local installation keys
      for (var key in installationsBox.keys) {
        if (key == '_admin_cached_key') continue;
        final data = installationsBox.get(key);
        if (data is Map) {
          final instName = data['name'] as String?;
          final guardKey = data['guardKey'] as String?;
          final clientKey = data['clientKey'] as String?;

          if (password == guardKey) {
            setState(() {
              _isLoading = false;
              _errorMessage = null;
            });
            if (mounted) {
              Navigator.pushReplacementNamed(
                context,
                '/dashboard',
                arguments: LoginSession(
                  role: UserRole.guardia,
                  installationName: instName,
                ),
              );
            }
            return;
          } else if (password == clientKey) {
            setState(() {
              _isLoading = false;
              _errorMessage = null;
            });
            if (mounted) {
              Navigator.pushReplacementNamed(
                context,
                '/dashboard',
                arguments: LoginSession(
                  role: UserRole.cliente,
                  installationName: instName,
                ),
              );
            }
            return;
          }
        }
      }

      setState(() {
        _isLoading = false;
        _errorMessage = 'Clave incorrecta. Verifica tu conexión si es tu primer ingreso.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: slate900,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header Logo / Icon
                const Icon(
                  Icons.shield_outlined,
                  size: 80,
                  color: Color(0xFF10B981),
                ),
                const SizedBox(height: 24),
                const Text(
                  'CONTROL DE ACCESO',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Ingresa tu clave asignada para iniciar el turno',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: slate400,
                  ),
                ),
                const SizedBox(height: 48),

                // Password Field Card
                Card(
                  elevation: 8,
                  shadowColor: Colors.black45,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'CLAVE DE ACCESO',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF10B981),
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordController,
                          obscureText: _obscureText,
                          style: const TextStyle(color: Colors.white, fontSize: 18),
                          decoration: InputDecoration(
                            hintText: '••••••••',
                            hintStyle: const TextStyle(color: slate500),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureText ? Icons.visibility : Icons.visibility_off,
                                color: slate400,
                              ),
                              onPressed: () {
                                setState(() {
                                  _obscureText = !_obscureText;
                                });
                              },
                            ),
                            enabledBorder: const UnderlineInputBorder(
                              borderSide: BorderSide(color: slate600),
                            ),
                            focusedBorder: const UnderlineInputBorder(
                              borderSide: BorderSide(color: Color(0xFF10B981), width: 2),
                            ),
                          ),
                          onSubmitted: (_) => _handleLogin(),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Icon(Icons.error_outline, color: Colors.redAccent, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Login Button
                ElevatedButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'INICIAR TURNO',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 1.0,
                          ),
                        ),
                ),
                const SizedBox(height: 48),

                // Help/Roles Info Section
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: slate800.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: slate700.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        '🔑 Control de Acceso Profesional:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF10B981),
                          fontSize: 13,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Las claves de acceso de los guardias, clientes e instalaciones son dinámicas y administradas de forma segura desde la base de datos de Supabase.',
                        style: TextStyle(color: slate300, fontSize: 12, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
