import 'package:flutter/material.dart';
import 'dart:math'; // Import the math library for Random

import 'debt_list_screen.dart';
import 'debt_plans_home.dart';
import 'debt_chat_screen.dart';
import 'debt_alerts_screen.dart';
import 'debt_report_screen.dart';
import 'credit_score_screen.dart';
import 'debt_notifications_screen.dart';

class DebtHome extends StatefulWidget {
  const DebtHome({super.key});

  @override
  State<DebtHome> createState() => _DebtHomeState();
}

class _DebtHomeState extends State<DebtHome> {
  late String _selectedQuote;

  // List of motivational quotes
  final List<String> _motivationalQuotes = [
    "Every payment you make is a step toward financial freedom. You're building a stronger future with each dollar you put toward your debts.",
    "Your commitment to paying off your debts shows real character and responsibility. Keep going - you're making progress that matters.",
    "Think of debt payments as investments in your peace of mind. Each payment reduces stress and opens up new possibilities for your money.",
    "Small consistent payments add up to big results. You don't have to do it all at once - just keep moving forward.",
    "Celebrate each milestone! Whether it's LKR 100 or LKR 1000 paid off, you're actively changing your financial situation for the better.",
    "Remember why you started this journey. Financial freedom isn't just about numbers - it's about the life you want to build.",
    "Imagine how it will feel when you make that final payment. That sense of accomplishment and relief is waiting for you.",
    "Your future self will thank you for every payment you make today. You're creating opportunities and reducing stress for tomorrow.",
    "Debt repayment is temporary, but the habits and confidence you're building will benefit you for life.",
    "Don't see debt payments as money leaving your pocket - see them as buying back your financial freedom.",
    "Every dollar you pay toward debt is a dollar working for your future instead of your past.",
    "You're not just paying bills - you're investing in a debt-free lifestyle that's closer than you think.",
    "You have the power to change your financial story. Every payment you make is you taking control of your narrative.",
    "Paying off debt takes courage and discipline - qualities that will serve you well beyond this financial challenge.",
    "You're stronger than your debt. You created a plan, and you have the ability to see it through.",
    "The interest stops growing when you eliminate the debt. Every extra payment today saves you money tomorrow.",
    "Missing payments makes the journey longer and more expensive. Staying consistent keeps you on the shortest path to freedom.",
    "Your debt didn't appear overnight, and it won't disappear overnight - but every payment makes it smaller and more manageable.",
    "Picture your first month without debt payments - all that money staying in your account for your goals and dreams.",
    "You're not just eliminating debt - you're creating space for savings, investments, and the things that truly matter to you.",
  ];

  @override
  void initState() {
    super.initState();
    // Select a random quote when the widget is first created
    final random = Random();
    _selectedQuote = _motivationalQuotes[random.nextInt(_motivationalQuotes.length)];
  }

  // A new widget to display the motivational quote.
  Widget _buildMotivationalQuoteCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      color: cs.secondaryContainer.withOpacity(0.5),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.secondaryContainer),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.tips_and_updates_outlined, color: cs.onSecondaryContainer, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                _selectedQuote,
                style: textTheme.bodyMedium?.copyWith(
                  color: cs.onSecondaryContainer,
                  fontStyle: FontStyle.italic,
                  height: 1.5, // Improved line spacing
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // The primary "hero" card for the AI Assistant feature.
  Widget _buildAiAssistantCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const DebtChatScreen())),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        elevation: 4,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [cs.primary, cs.primaryContainer],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.chat_bubble_outline, color: cs.onPrimary, size: 40),
              const SizedBox(height: 12),
              Text(
                'AI Assistant',
                style: textTheme.headlineSmall?.copyWith(
                  color: cs.onPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Ask for personalized advice on your debt',
                style: textTheme.bodyMedium
                    ?.copyWith(color: cs.onPrimary.withOpacity(0.9)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // A compact item for the secondary features grid.
  Widget _buildGridItem(BuildContext context,
      {required IconData icon,
        required String title,
        required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        color: cs.surfaceVariant.withOpacity(0.5),
        elevation: 0,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 30, color: cs.primary),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debt Management'),
        actions: [
          IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.pushNamed(context, '/settings'))
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Motivational Quote Card
            _buildMotivationalQuoteCard(context),

            const SizedBox(height: 24),

            // Main Feature Card
            _buildAiAssistantCard(context),

            const SizedBox(height: 24),

            // Sub-header for the tool grid
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: Text(
                'Debt Toolkit',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: Colors.black54),
              ),
            ),

            const SizedBox(height: 12),

            // Grid for all other features
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.0,
              children: [
                _buildGridItem(
                  context,
                  icon: Icons.list_alt_outlined,
                  title: 'Overview',
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const DebtListScreen())),
                ),
                _buildGridItem(
                  context,
                  icon: Icons.calculate_outlined,
                  title: 'Payoff Plans',
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const DebtPlansHome())),
                ),
                _buildGridItem(
                  context,
                  icon: Icons.insert_chart_outlined,
                  title: 'Reports',
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const DebtReportScreen())),
                ),
                _buildGridItem(
                  context,
                  icon: Icons.add_alert_outlined,
                  title: 'Create Alerts',
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const DebtAlertsScreen())),
                ),
                _buildGridItem(
                  context,
                  icon: Icons.notifications_active_outlined,
                  title: 'Reminders',
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const DebtNotificationsScreen())),
                ),
                _buildGridItem(
                  context,
                  icon: Icons.military_tech_outlined,
                  title: 'Credit Score',
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CreditScoreScreen())),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}