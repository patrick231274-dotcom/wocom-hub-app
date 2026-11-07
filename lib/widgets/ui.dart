import 'package:flutter/material.dart';

import '../services/session.dart';
import '../theme.dart';

/// Presence colours shared by every screen.
Color statusColor(String status) => switch (status) {
      'available' => const Color(0xFF22C55E),
      'on_call' || 'dnd' => const Color(0xFFDC2626),
      'away' || 'lunch' || 'meeting' || 'ringing' => const Color(0xFFF59E0B),
      _ => const Color(0xFFA8A0B4),
    };

Color statusTextColor(String status) => switch (status) {
      'available' => const Color(0xFF15803D),
      'on_call' || 'dnd' => const Color(0xFFB91C1C),
      'away' || 'lunch' || 'meeting' || 'ringing' => const Color(0xFFB45309),
      _ => const Color(0xFF6B6478),
    };

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  final first = parts.first[0];
  final second = parts.length > 1 ? parts[1][0] : (parts.first.length > 1 ? parts.first[1] : '');
  return (first + second).toUpperCase();
}

/// Round initials avatar with an optional presence dot.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.status, this.size = 44, this.onDark = false, this.group = false});

  final String name;
  final String? status;
  final double size;
  final bool onDark;
  final bool group;

  @override
  Widget build(BuildContext context) {
    final bg = onDark ? Colors.white.withValues(alpha: 0.22) : (group ? wocomDeep : wocomTintLight);
    final fg = onDark || group ? Colors.white : wocomDeep;
    final ring = onDark ? wocomDeep : Theme.of(context).scaffoldBackgroundColor;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(initialsOf(name), style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: size * 0.36)),
        ),
        if (status != null)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: size * 0.3,
              height: size * 0.3,
              decoration: BoxDecoration(color: statusColor(status!), shape: BoxShape.circle, border: Border.all(color: ring, width: 2.5)),
            ),
          ),
      ]),
    );
  }
}

/// The plum header every main screen shares: my avatar (opens My status), a title, a subtitle,
/// optional trailing buttons, and an optional search field underneath.
class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key, required this.title, this.subtitle, this.onAvatarTap, this.myStatus, this.trailing = const [], this.search, this.bottom, this.leading, this.onMenuTap});

  final String title;
  final String? subtitle;
  final VoidCallback? onAvatarTap;
  final String? myStatus;
  final List<Widget> trailing;
  final ValueChanged<String>? search;
  final Widget? bottom;
  final Widget? leading;
  final VoidCallback? onMenuTap;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      padding: EdgeInsets.fromLTRB(16, top + 14, 16, 16),
      decoration: const BoxDecoration(
        gradient: wocomGradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Color(0x33321062), blurRadius: 14, offset: Offset(0, 6))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (leading != null) leading!
          else if (onMenuTap != null)
            IconButton(tooltip: 'Menu', icon: const Icon(Icons.menu, color: Colors.white, size: 26), onPressed: onMenuTap, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 40, minHeight: 44)),
          if (leading != null || onMenuTap != null) const SizedBox(width: 6),
          Semantics(
            button: true,
            label: 'My status',
            child: GestureDetector(
              onTap: onAvatarTap,
              child: PersonAvatar(name: Session.instance.name, status: myStatus ?? 'available', onDark: true),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
              if (subtitle != null)
                Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: wocomTintLight, fontSize: 12.5)),
            ]),
          ),
          ...trailing,
        ]),
        if (search != null) ...[
          const SizedBox(height: 14),
          SizedBox(
            height: 44,
            child: TextField(
              onChanged: search,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.white,
              decoration: InputDecoration(
                hintText: 'Search',
                hintStyle: const TextStyle(color: wocomTintLight),
                prefixIcon: const Icon(Icons.search, color: wocomTintLight),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.18),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white70)),
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
        ],
        if (bottom != null) ...[const SizedBox(height: 14), bottom!],
      ]),
    );
  }
}

/// Square-ish light button used for call / chat actions in lists.
class SoftIconButton extends StatelessWidget {
  const SoftIconButton({super.key, required this.icon, required this.label, required this.onTap, this.filled = true});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: Material(
          color: filled ? wocomSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 21, color: wocomDeep, semanticLabel: label)),
          ),
        ),
      );
}

/// Friendly empty / error state.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: const Color(0xFFB9A9D6)),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF5E5670), fontSize: 14.5, height: 1.4)),
            if (action != null) ...[const SizedBox(height: 14), action!],
          ]),
        ),
      );
}

String timeAgoLabel(DateTime t) {
  final now = DateTime.now();
  final local = t.toLocal();
  final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final hm = '$h:${local.minute.toString().padLeft(2, '0')} ${local.hour < 12 ? 'am' : 'pm'}';
  if (now.year == local.year && now.month == local.month && now.day == local.day) return hm;
  final yesterday = now.subtract(const Duration(days: 1));
  if (yesterday.year == local.year && yesterday.month == local.month && yesterday.day == local.day) return 'Yesterday';
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  if (now.difference(local).inDays < 7) return days[local.weekday - 1];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[local.month - 1]} ${local.day}';
}
