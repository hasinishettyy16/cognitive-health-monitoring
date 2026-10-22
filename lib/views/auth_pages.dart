import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../services/firestore_service.dart';

final RegExp _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

String _authError(FirebaseAuthException e) {
  switch (e.code) {
    case 'invalid-email':
      return 'That email address is not valid.';
    case 'user-not-found':
    case 'wrong-password':
    case 'invalid-credential':
      return 'Incorrect email or password.';
    case 'user-disabled':
      return 'This account has been disabled.';
    case 'too-many-requests':
      return 'Too many attempts. Please try again later.';
    case 'network-request-failed':
      return 'No internet connection.';
    case 'email-already-in-use':
      return 'An account with this email already exists.';
    case 'weak-password':
      return 'Password is too weak (use at least 6 characters).';
    default:
      return e.message ?? 'Authentication failed.';
  }
}

// ---------------------------------------------------------------------------
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.self_improvement, size: 96, color: cs.primary),
              const SizedBox(height: 16),
              Text(
                'Yoga & Cognition Study',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '15-day Anulom-Vilom practice with wearable sensing and a daily memory puzzle.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              FilledButton(
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const LoginScreen())),
                child: const Padding(padding: EdgeInsets.all(14), child: Text('Log in')),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const SignupScreen())),
                child: const Padding(padding: EdgeInsets.all(14), child: Text('Create account')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hide = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _email.text.trim();
    final pw = _password.text;
    if (email.isEmpty || pw.isEmpty) {
      _snack(context, 'Please enter your email and password.');
      return;
    }
    if (!_emailRegex.hasMatch(email)) {
      _snack(context, 'Please enter a valid email address.');
      return;
    }
    setState(() => _busy = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: pw);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on FirebaseAuthException catch (e) {
      if (mounted) _snack(context, _authError(e));
    } catch (_) {
      if (mounted) _snack(context, 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log in')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: _hide,
            decoration: InputDecoration(
              labelText: 'Password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hide = !_hide),
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _login,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Log in'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _participant = TextEditingController();
  final _age = TextEditingController();
  String? _gender;
  bool _busy = false;
  bool _hide = true;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _participant.dispose();
    _age.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    final pw = _password.text;
    final pid = _participant.text.trim();
    final age = int.tryParse(_age.text.trim());

    if (name.isEmpty || email.isEmpty || pw.isEmpty || pid.isEmpty) {
      _snack(context, 'Please fill in name, email, password and participant ID.');
      return;
    }
    if (!_emailRegex.hasMatch(email)) {
      _snack(context, 'Please enter a valid email address.');
      return;
    }
    if (pw.length < 6) {
      _snack(context, 'Password must be at least 6 characters.');
      return;
    }
    if (age == null || age < 10 || age > 100) {
      _snack(context, 'Please enter a valid age.');
      return;
    }
    if (_gender == null) {
      _snack(context, 'Please select a gender option.');
      return;
    }

    setState(() => _busy = true);
    try {
      final cred = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: pw);
      final user = cred.user;
      if (user != null) {
        await user.updateDisplayName(name);
        await FirestoreService.createUserProfile(user.uid, {
          'name': name,
          'email': email,
          'participantId': pid,
          'age': age,
          'gender': _gender,
        });
      }
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on FirebaseAuthException catch (e) {
      if (mounted) _snack(context, _authError(e));
    } catch (_) {
      if (mounted) _snack(context, 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: _hide,
            decoration: InputDecoration(
              labelText: 'Password (min 6 characters)',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hide = !_hide),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _participant,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Participant ID (e.g. 1BY24EC060)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _age,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Age', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          const Text('Gender'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final g in StudyConfig.genders)
                ChoiceChip(
                  label: Text(g),
                  selected: _gender == g,
                  onSelected: (_) => setState(() => _gender = g),
                ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _signup,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Create account'),
            ),
          ),
        ],
      ),
    );
  }
}
