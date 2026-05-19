import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';
import 'home_screen.dart';

/// First-launch screen where the user creates a 6-digit PIN.
///
/// State machine:  entering → confirming → saving
class SetupPinScreen extends StatefulWidget {
  const SetupPinScreen({super.key});

  @override
  State<SetupPinScreen> createState() => _SetupPinScreenState();
}

enum _Step { entering, confirming, saving }

class _SetupPinScreenState extends State<SetupPinScreen> {
  static const _pinLength = 6;

  _Step _step = _Step.entering;
  String _firstPin = '';
  String _input = '';
  String? _errorText;

  void _onDigit(String digit) {
    if (_input.length >= _pinLength || _step == _Step.saving) return;
    setState(() {
      _input += digit;
      _errorText = null;
    });
    if (_input.length == _pinLength) _advance(_input);
  }

  void _onDelete() {
    if (_input.isEmpty || _step == _Step.saving) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  void _advance(String pin) {
    if (_step == _Step.entering) {
      setState(() {
        _firstPin = pin;
        _step = _Step.confirming;
        _input = '';
      });
      return;
    }
    // Confirming
    if (pin == _firstPin) {
      _save(pin);
    } else {
      setState(() {
        _errorText = 'PINs do not match — try again.';
        _step = _Step.entering;
        _firstPin = '';
        _input = '';
      });
    }
  }

  Future<void> _save(String pin) async {
    setState(() => _step = _Step.saving);
    await context.read<AuthService>().setPin(pin);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  String get _title => switch (_step) {
        _Step.entering => 'Create a PIN',
        _Step.confirming => 'Confirm your PIN',
        _Step.saving => 'Setting up…',
      };

  String get _subtitle => switch (_step) {
        _Step.entering =>
          'Choose a 6-digit PIN to protect\nyour messages and files.',
        _Step.confirming => 'Enter your PIN again to confirm.',
        _Step.saving => '',
      };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final saving = _step == _Step.saving;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 64,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _subtitle,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface.withAlpha(153),
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  _PinDots(
                    filled: _input.length,
                    total: _pinLength,
                    color: _errorText != null
                        ? colorScheme.error
                        : colorScheme.primary,
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _errorText!,
                      style: TextStyle(
                          color: colorScheme.error, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 28),
                  if (saving)
                    const CircularProgressIndicator()
                  else
                    _NumberPad(
                      onDigit: _onDigit,
                      onDelete: _onDelete,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Lock screen ─────────────────────────────────────────────────────────────

/// Lock screen shown every time the app opens (or resumes from background).
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  static const _pinLength = 6;

  String _input = '';
  bool _checking = false;
  String? _errorText;
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final auth = context.read<AuthService>();
    final canBio = await auth.canUseBiometric();
    if (!mounted) return;
    setState(() => _biometricAvailable = canBio);
    if (canBio) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    final success =
        await context.read<AuthService>().authenticateWithBiometric();
    if (success) _unlock();
  }

  void _onDigit(String digit) {
    if (_input.length >= _pinLength || _checking) return;
    setState(() {
      _input += digit;
      _errorText = null;
    });
    if (_input.length == _pinLength) _checkPin(_input);
  }

  void _onDelete() {
    if (_input.isEmpty || _checking) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  Future<void> _checkPin(String pin) async {
    setState(() => _checking = true);
    final correct = await context.read<AuthService>().verifyPin(pin);
    if (!mounted) return;
    if (correct) {
      _unlock();
    } else {
      setState(() {
        _checking = false;
        _errorText = 'Incorrect PIN. Try again.';
        _input = '';
      });
    }
  }

  void _unlock() {
    context.read<AuthService>().unlock();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_rounded,
                    size: 64,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'MeshShare is locked',
                    style:
                        Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _biometricAvailable
                        ? 'Use biometrics or enter your PIN.'
                        : 'Enter your PIN to continue.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface.withAlpha(153),
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  _PinDots(
                    filled: _input.length,
                    total: _pinLength,
                    color: _errorText != null
                        ? colorScheme.error
                        : colorScheme.primary,
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _errorText!,
                      style: TextStyle(
                          color: colorScheme.error, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 28),
                  if (_checking)
                    const CircularProgressIndicator()
                  else
                    _NumberPad(
                      onDigit: _onDigit,
                      onDelete: _onDelete,
                    ),
                  if (_biometricAvailable && !_checking) ...[
                    const SizedBox(height: 20),
                    FilledButton.tonalIcon(
                      onPressed: _tryBiometric,
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('Use biometric'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Shared widgets ──────────────────────────────────────────────────────────

class _PinDots extends StatelessWidget {
  final int filled;
  final int total;
  final Color color;

  const _PinDots({required this.filled, required this.total, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < filled ? color : Colors.transparent,
            border: Border.all(color: color, width: 2),
          ),
        );
      }),
    );
  }
}

class _NumberPad extends StatelessWidget {
  final void Function(String digit) onDigit;
  final VoidCallback onDelete;

  const _NumberPad({required this.onDigit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const digits = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];

    Widget digitButton(String label) => _PadButton(
          onTap: () => onDigit(label),
          child: Text(
            label,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w500),
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in digits)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: row.map(digitButton).toList(),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 80, height: 72), // blank spacer
            digitButton('0'),
            _PadButton(
              onTap: onDelete,
              child: Icon(Icons.backspace_outlined,
                  color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

class _PadButton extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;

  const _PadButton({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 80,
      height: 72,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(40),
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    );
  }
}
