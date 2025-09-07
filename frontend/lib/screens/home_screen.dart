import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../providers/entry_provider.dart';
import 'entries_list_screen.dart';
import 'add_entry_form.dart';
import 'ocr_upload_screen.dart';
import 'summary_screen.dart';
import 'settings_page.dart';
import 'user/login_screen.dart';
import 'user/profile_screen.dart';
import 'forecast_screen.dart';
import 'investment/investment_home.dart';
import 'debt/debt_home.dart';
import 'savings/cost_savings_home.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Logout')),
        ],
      ),
    );

    if (confirmed != true) return;

    await AuthService.clear();

    try {
      context.read<EntryProvider>().clearForLogout();
    } catch (_) {}

    if (context.mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
            (route) => false,
      );
    }
  }

  // --- WIDGETS ---
  // Kept the original _tile for the bottom section
  Widget _tile(
      BuildContext c, {
        required String label,
        required IconData icon,
        required VoidCallback onTap,
        Color? color,
      }) {
    final cs = Theme.of(c).colorScheme;
    final bg = color ?? cs.primaryContainer;
    final fg = cs.onPrimaryContainer;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 32, color: fg),
            const SizedBox(height: 12),
            Text(label, textAlign: TextAlign.center, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // User card at the top
  Widget _userCard(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: AuthService.userNotifier,
      builder: (context, user, _) {
        final name = (user != null && user['name'] != null && (user['name'] as String).isNotEmpty) ? user['name'] as String : 'User';
        final email = (user != null && user['email'] != null) ? user['email'] as String : '';
        final theme = Theme.of(context);

        return Card(
          elevation: 0,
          color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: theme.colorScheme.primary,
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : 'U',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  if (email.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(email, style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
                  ],
                ]),
              ),
              IconButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit Profile',
              ),
            ]),
          ),
        );
      },
    );
  }

  // NEW: Small, prominent action buttons at the top
  Widget _buildQuickActions(BuildContext context) {
    final theme = Theme.of(context);
    Widget actionButton({required IconData icon, required String label, required VoidCallback onTap, required Color color}) {
      return Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Icon(icon, size: 28, color: theme.colorScheme.onSecondaryContainer),
                const SizedBox(height: 8),
                Text(label, style: TextStyle(color: theme.colorScheme.onSecondaryContainer, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        actionButton(
          icon: Icons.document_scanner_outlined,
          label: 'Scan Receipt',
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OcrUploadScreen())),
          color: theme.colorScheme.secondaryContainer,
        ),
        const SizedBox(width: 12),
        actionButton(
          icon: Icons.add_circle_outline,
          label: 'Add Entry',
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AddEntryForm())),
          color: theme.colorScheme.tertiaryContainer,
        ),
        const SizedBox(width: 12),
        actionButton(
          icon: Icons.trending_up,
          label: 'Status Forecast',
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ForecastScreen())),
          color: theme.colorScheme.primaryContainer,
        ),
      ],
    );
  }

  // NEW: Large cards for the main modules
  Widget _buildMainFeatureCard(
      BuildContext context, {
        required String title,
        required String subtitle,
        required IconData icon,
        required VoidCallback onTap,
        required Color startColor,
        required Color endColor,
      }) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [startColor, endColor],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [BoxShadow(color: startColor.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
        ),
        child: Row(
          children: [
            Icon(icon, size: 40, color: Colors.white),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withOpacity(0.9))),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Finance Dashboard'),
        actions: [
          IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()))),
          IconButton(icon: const Icon(Icons.logout), onPressed: () => _logout(context)),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _userCard(context),
              const SizedBox(height: 24),

              _buildQuickActions(context),
              const SizedBox(height: 24),

              _buildMainFeatureCard(
                context,
                title: 'Manage Investments',
                subtitle: 'Track stocks, commondities etc.',
                icon: Icons.show_chart,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InvestmentHome())),
                startColor: Colors.teal.shade400,
                endColor: Colors.teal.shade600,
              ),
              const SizedBox(height: 16),

              _buildMainFeatureCard(
                context,
                title: 'Manage Debt',
                subtitle: 'Monitor loans and credit payments.',
                icon: Icons.credit_card_off,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DebtHome())),
                startColor: Colors.orange.shade400,
                endColor: Colors.orange.shade600,
              ),
              const SizedBox(height: 16),

              _buildMainFeatureCard(
                context,
                title: 'Manage Cost Savings',
                subtitle: 'Identify and track savings goals.',
                icon: Icons.savings_outlined,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CostSavingsHome())),
                startColor: Colors.blue.shade400,
                endColor: Colors.blue.shade600,
              ),
              const SizedBox(height: 24),

              // Other options placed in a 2-column row at the bottom
              Row(
                children: [
                  Expanded(
                    child: _tile(
                      context,
                      label: 'All Entries',
                      icon: Icons.list_alt_outlined,
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EntriesListScreen())),
                      color: theme.colorScheme.surfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _tile(
                      context,
                      label: 'View Summary',
                      icon: Icons.pie_chart_outline,
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SummaryScreen())),
                      color: theme.colorScheme.surfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}