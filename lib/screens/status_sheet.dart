import 'package:flutter/material.dart';

import '../brand.dart';

import '../services/hub.dart';
import '../services/native_call.dart';
import '../services/phone.dart';
import '../services/session.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Tap your photo: set your status (the same states as the Hub; anything but Available sends
/// callers to voicemail), see your account, sign out.
Future<void> showStatusSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => const _StatusSheet(),
  );
}

class _StatusSheet extends StatelessWidget {
  const _StatusSheet();

  static const _states = [
    ('available', 'Available', 'Calls and chats reach you'),
    ('away', 'Away', 'Calls go to voicemail'),
    ('meeting', 'In a meeting', 'Calls go to voicemail'),
    ('lunch', 'At lunch', 'Calls go to voicemail'),
    ('dnd', 'Do not disturb', 'No calls; callers reach voicemail'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    return AnimatedBuilder(
      animation: Hub.instance,
      builder: (context, _) {
        final current = Hub.instance.myStatus;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                PersonAvatar(name: s.name, status: current, size: 56, group: true),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    Text('${Phone.instance.extension.isEmpty ? '' : 'Ext ${Phone.instance.extension} · '}${s.company}', style: const TextStyle(color: Color(0xFF5E5670))),
                  ]),
                ),
              ]),
              const Padding(
                padding: EdgeInsets.only(top: 18, bottom: 6),
                child: Text('SET MY STATUS', style: TextStyle(fontSize: 12.5, letterSpacing: 1, fontWeight: FontWeight.w700, color: Color(0xFF6B6478))),
              ),
              for (final (value, label, hint) in _states)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: current == value ? wocomSoft : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: current == value ? wocomDeep : wocomLine, width: current == value ? 2 : 1),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        final err = await Hub.instance.setStatus(value);
                        if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        child: Row(children: [
                          Container(width: 14, height: 14, decoration: BoxDecoration(color: statusColor(value), shape: BoxShape.circle)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                              Text(hint, style: const TextStyle(color: Color(0xFF5E5670), fontSize: 13)),
                            ]),
                          ),
                          if (current == value) const Icon(Icons.check_circle, color: wocomDeep),
                        ]),
                      ),
                    ),
                  ),
                ),
              if (Hub.instance.inQueue) ...[
                const Divider(height: 28),
                AnimatedBuilder(
                  animation: Hub.instance,
                  builder: (context, _) {
                    final hub = Hub.instance;
                    final benched = hub.queueBenched;
                    return Container(
                      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                      decoration: BoxDecoration(color: benched ? const Color(0xFFFFF4DB) : const Color(0xFFE7F6EC), borderRadius: BorderRadius.circular(14)),
                      child: Row(children: [
                        Icon(benched ? Icons.pause_circle_outline : Icons.headset_mic_outlined, color: benched ? const Color(0xFFB45309) : const Color(0xFF15803D)),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(benched ? 'Queue: ${hub.myQueueStatus}' : 'Queue: taking calls', style: TextStyle(fontWeight: FontWeight.w800, color: benched ? const Color(0xFF92400E) : const Color(0xFF166534))),
                          Text(benched ? 'The queue is not sending you calls until you set yourself available.' : 'Queue calls ring this phone.', style: const TextStyle(fontSize: 12.5, color: wocomMuted)),
                        ])),
                        TextButton(
                          onPressed: () async {
                            final err = await hub.setQueueStatus(benched ? 'Available' : 'On Break');
                            if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                          },
                          child: Text(benched ? 'Go available' : 'Take a break'),
                        ),
                      ]),
                    );
                  },
                ),
              ],
              const Divider(height: 28),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: () async {
                  Navigator.pop(context);
                  Hub.instance.stop();
                  NativeCall.instance.release();
                  Phone.instance.disconnect();
                  await Session.instance.signOut();
                },
              ),
              const Text('${Brand.name} · test build', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF8A8296), fontSize: 12)),
            ]),
          ),
        );
      },
    );
  }
}
