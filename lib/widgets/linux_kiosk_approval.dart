import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/linux_kiosk_campaign.dart';

/// Asks the person at the screen whether a clashing kiosk campaign may run
/// (Linux only). It covers signage or the kiosk, but the service never offers
/// it during a customer session. Touch, mouse and keyboard all work: Tab moves
/// between the buttons, Enter chooses, Esc moves to Decline. Remote view
/// clicks reach it like any other control.
class LinuxKioskApprovalOverlay extends StatelessWidget {
  final KioskCampaignService kiosk;
  const LinuxKioskApprovalOverlay({super.key, required this.kiosk});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<KioskApproval?>(
      valueListenable: kiosk.approvalPrompt,
      builder: (_, approval, __) => approval == null
          ? const SizedBox.shrink()
          : _ApprovalPrompt(
              key: ValueKey('kiosk-approval-${approval.requestId}'),
              approval: approval,
              kiosk: kiosk,
            ),
    );
  }
}

class _ApprovalPrompt extends StatefulWidget {
  final KioskApproval approval;
  final KioskCampaignService kiosk;
  const _ApprovalPrompt({super.key, required this.approval, required this.kiosk});

  @override
  State<_ApprovalPrompt> createState() => _ApprovalPromptState();
}

class _ApprovalPromptState extends State<_ApprovalPrompt> {
  static const _violet = Color(0xFF8B5CF6);
  static const _ink = Color(0xFF111827);
  static const _muted = Color(0xFF4B5563);

  final _approveFocus = FocusNode(debugLabel: 'kiosk-approve');
  final _declineFocus = FocusNode(debugLabel: 'kiosk-decline');

  /// Which answer is being sent (null: none). Blocks double taps.
  bool? _sending;
  String? _error;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // "Expires in 23 h" stays current.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _approveFocus.dispose();
    _declineFocus.dispose();
    super.dispose();
  }

  Future<void> _answer(bool approve) async {
    if (_sending != null) return;
    setState(() {
      _sending = approve;
      _error = null;
    });
    final result = await widget.kiosk.decideApproval(widget.approval, approve: approve);
    if (!mounted) return;
    // Sent or gone: the service hides the prompt. Failed: it stays.
    setState(() {
      _sending = null;
      _error = result == KioskApprovalSend.failed ? 'Could not send. Try again.' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.approval;
    final expires = a.expiresIn(DateTime.now());
    final busy = _sending != null;
    return SizedBox.expand(
      child: Material(
        color: const Color(0xCC000000),
        child: Shortcuts(
          shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): _ToDecline()},
          child: Actions(
            actions: {
              _ToDecline: CallbackAction<_ToDecline>(onInvoke: (_) {
                _declineFocus.requestFocus();
                return null;
              }),
            },
            child: FocusTraversalGroup(
              child: Center(
                child: LayoutBuilder(builder: (context, box) {
                  // Readable from about 2 m on 1080p, scales up on 4K.
                  final scale = (box.maxWidth / 1280).clamp(0.9, 2.2).toDouble();
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 760 * scale),
                    child: Container(
                      margin: EdgeInsets.all(24 * scale),
                      padding: EdgeInsets.all(32 * scale),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20 * scale),
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('New kiosk campaign',
                                style: TextStyle(fontSize: 16 * scale, fontWeight: FontWeight.w600, color: _violet)),
                            SizedBox(height: 8 * scale),
                            Text(a.name,
                                style: TextStyle(fontSize: 34 * scale, fontWeight: FontWeight.w700, color: _ink)),
                            SizedBox(height: 6 * scale),
                            Text(a.schedule.describe(),
                                style: TextStyle(fontSize: 22 * scale, color: _muted)),
                            if (a.replaces.isNotEmpty) ...[
                              SizedBox(height: 20 * scale),
                              Text('It would replace:',
                                  style: TextStyle(fontSize: 18 * scale, fontWeight: FontWeight.w600, color: _ink)),
                              SizedBox(height: 6 * scale),
                              for (final r in a.replaces)
                                Padding(
                                  padding: EdgeInsets.only(bottom: 4 * scale),
                                  child: Text('${r.name} · ${r.schedule.describe()}',
                                      style: TextStyle(fontSize: 18 * scale, color: _muted)),
                                ),
                            ],
                            if (expires != null) ...[
                              SizedBox(height: 16 * scale),
                              Text(expires, style: TextStyle(fontSize: 15 * scale, color: _muted)),
                            ],
                            if (_error != null) ...[
                              SizedBox(height: 16 * scale),
                              Text(_error!,
                                  style: TextStyle(
                                      fontSize: 17 * scale,
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFFB91C1C))),
                            ],
                            SizedBox(height: 28 * scale),
                            Row(children: [
                              Expanded(
                                child: _button(
                                  label: 'Decline',
                                  focus: _declineFocus,
                                  primary: false,
                                  sending: _sending == false,
                                  enabled: !busy,
                                  scale: scale,
                                  onPressed: () => _answer(false),
                                ),
                              ),
                              SizedBox(width: 16 * scale),
                              Expanded(
                                child: _button(
                                  label: 'Approve',
                                  focus: _approveFocus,
                                  primary: true,
                                  autofocus: true,
                                  sending: _sending == true,
                                  enabled: !busy,
                                  scale: scale,
                                  onPressed: () => _answer(true),
                                ),
                              ),
                            ]),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _button({
    required String label,
    required FocusNode focus,
    required bool primary,
    required bool sending,
    required bool enabled,
    required double scale,
    required VoidCallback onPressed,
    bool autofocus = false,
  }) {
    final child = sending
        ? SizedBox(
            width: 24 * scale,
            height: 24 * scale,
            child: CircularProgressIndicator(strokeWidth: 3, color: primary ? Colors.white : _violet),
          )
        : Text(label, style: TextStyle(fontSize: 22 * scale, fontWeight: FontWeight.w600));
    final style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size.fromHeight(64 * scale)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12 * scale))),
      side: primary ? null : const WidgetStatePropertyAll(BorderSide(color: Color(0xFFD1D5DB), width: 1.5)),
      backgroundColor: primary
          ? WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? const Color(0xFFC4B5FD) : _violet)
          : null,
      foregroundColor: WidgetStatePropertyAll(primary ? Colors.white : _ink),
      overlayColor: WidgetStatePropertyAll(primary ? Colors.white24 : const Color(0x148B5CF6)),
    );
    return primary
        ? FilledButton(
            focusNode: focus,
            autofocus: autofocus,
            style: style,
            onPressed: enabled ? onPressed : null,
            child: child,
          )
        : OutlinedButton(
            focusNode: focus,
            autofocus: autofocus,
            style: style,
            onPressed: enabled ? onPressed : null,
            child: child,
          );
  }
}

class _ToDecline extends Intent {
  const _ToDecline();
}
