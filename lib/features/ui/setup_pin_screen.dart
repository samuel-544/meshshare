import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../auth/auth_service.dart';
import 'home_screen.dart';
import 'widgets/mesh_logo.dart';

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
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
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
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const MeshLogo(size: 84),
                        const SizedBox(height: 28),
                        Text(
                          _title,
                          style: Theme.of(context).textTheme.displaySmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _subtitle,
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
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
                              color: colorScheme.error,
                              fontSize: 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: 28),
                        if (saving)
                          const CircularProgressIndicator()
                        else
                          _NumberPad(onDigit: _onDigit, onDelete: _onDelete),
                      ],
                    ),
                  ),
                ),
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
    final success = await context
        .read<AuthService>()
        .authenticateWithBiometric();
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
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const MeshLogo(size: 84),
                        const SizedBox(height: 28),
                        Text(
                          'MeshShare is locked',
                          style: Theme.of(context).textTheme.displaySmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _biometricAvailable
                              ? 'Use biometrics or enter your PIN.'
                              : 'Enter your PIN to continue.',
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
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
                              color: colorScheme.error,
                              fontSize: 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: 28),
                        if (_checking)
                          const CircularProgressIndicator()
                        else
                          _NumberPad(onDigit: _onDigit, onDelete: _onDelete),
                        if (_biometricAvailable && !_checking) ...[
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: _tryBiometric,
                            icon: const Icon(
                              Icons.fingerprint,
                              color: MeshColors.copper,
                            ),
                            label: const Text('Use biometric'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 46),
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
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

  const _PinDots({
    required this.filled,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final on = i < filled;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 7),
          width: on ? 13 : 11,
          height: on ? 13 : 11,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? color : Colors.transparent,
            border: Border.all(
              color: on ? color : MeshColors.outline,
              width: 1.6,
            ),
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
    const digits = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];

    Widget digitButton(String label) => _PadButton(
      onTap: () => onDigit(label),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w600,
          color: MeshColors.text,
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in digits)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: row.map(digitButton).toList(),
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 84, height: 64),
            digitButton('0'),
            _PadButton(
              onTap: onDelete,
              filled: false,
              child: const Icon(
                Icons.backspace_outlined,
                color: MeshColors.textDim,
                size: 22,
              ),
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
  final bool filled;

  const _PadButton({required this.onTap, required this.child, this.filled = true});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Material(
        color: filled ? MeshColors.surfaceHigh : Colors.transparent,
        shape: CircleBorder(
          side: filled
              ? const BorderSide(color: MeshColors.outline)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 64,
            height: 64,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
