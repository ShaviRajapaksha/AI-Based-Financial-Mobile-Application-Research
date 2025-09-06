import 'package:flutter/material.dart';
import 'dart:math'; // Import the math library for Random

import 'cost_savings_chat_screen.dart';
import 'savings_goals_screen.dart';
import 'savings_report_screen.dart';
import 'goal_notifications_screen.dart';

class CostSavingsHome extends StatefulWidget {
  const CostSavingsHome({super.key});

  @override
  State<CostSavingsHome> createState() => _CostSavingsHomeState();
}

class _CostSavingsHomeState extends State<CostSavingsHome> {
  late String _selectedQuote;

  // List of motivational quotes for saving costs
  final List<String> _motivationalQuotes = [
    "Every dollar you don't spend is a dollar you get to keep. Small savings add up faster than you think.",
    "Before buying something, ask yourself: 'Do I need this, or do I just want it?' Your future self will appreciate the pause.",
    "Track your spending for just one week - you'll be surprised where your money actually goes.",
    "That daily coffee might seem small, but saving LKR 200 a day equals LKR 6000 a month in your pocket.",
    "You have more control over your expenses than you realize. Every purchase is a choice you get to make.",
    "Cutting expenses isn't about depriving yourself - it's about being intentional with your money.",
    "You're not being cheap, you're being smart. There's a big difference.",
    "Every subscription you cancel, every unnecessary purchase you avoid, puts money back where it belongs - with you.",
    "Cook one more meal at home this week. Your wallet and your health will both thank you.",
    "Before you buy it, sleep on it. If you still want it tomorrow, at least it was a thoughtful decision.",
    "Check your subscriptions this month. Cancel what you don't actively use - it's free money.",
    "Compare prices before you buy. Two minutes of research can save you real money.",
    "Small changes create big results. Start with one expense category and build from there.",
    "You're building a habit of mindful spending. Each conscious choice makes the next one easier.",
    "Celebrate your wins! Every dollar saved is proof that you can take control of your spending.",
    "You're not cutting expenses forever - you're creating breathing room in your budget.",
    "Spending less doesn't mean living less - it means living more intentionally.",
    "The best purchases are often the ones you don't make. Your bank account will show the difference.",
    "Free and cheap activities can be just as enjoyable as expensive ones. Challenge yourself to find them.",
    "Your money should work for your priorities, not disappear on autopilot. Take back control, one expense at a time.",
  ];

  @override
  void initState() {
    super.initState();
    // Select a random quote when the widget is first created
    final random = Random();
    _selectedQuote =
    _motivationalQuotes[random.nextInt(_motivationalQuotes.length)];
  }

  // A new widget to display the motivational quote.
  Widget _buildMotivationalQuoteCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      color: cs.surfaceVariant.withOpacity(0.6),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.tips_and_updates_outlined,
                color: cs.onSurfaceVariant, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                _selectedQuote,
                style: textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
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

  // This is the primary card for the AI Assistant.
  Widget _buildAiAssistantCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ExpenseChatScreen()),
      ),
      child: Card(
        // Using a gradient to make it stand out
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior:
        Clip.antiAlias, // Ensures the gradient respects the border radius
        elevation: 4,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                cs.primary,
                HSLColor.fromColor(cs.primary).withLightness(0.4).toColor()
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.smart_toy_outlined, color: cs.onPrimary, size: 40),
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
                'Ask for personalized advice with voice input',
                style: textTheme.bodyMedium
                    ?.copyWith(color: cs.onPrimary.withOpacity(0.9)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // A tile for secondary options.
  Widget _tile(
      BuildContext context, {
        required IconData icon,
        required String title,
        required VoidCallback onTap,
      }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Row(children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: cs.secondaryContainer,
            child: Icon(icon, color: cs.onSecondaryContainer),
          ),
          const SizedBox(width: 16),
          Expanded(
            child:
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Icon(Icons.chevron_right, color: Colors.grey.shade600)
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cost Savings Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Motivational Quote Card
          _buildMotivationalQuoteCard(context),

          const SizedBox(height: 24),

          // Main "Hero" component
          _buildAiAssistantCard(context),

          const SizedBox(height: 24),

          // Sub-header for other tools
          Text(
            'Cost Savings Toolkit',
            style: textTheme.titleMedium?.copyWith(color: Colors.black54),
          ),

          const SizedBox(height: 8),

          // Grouping the secondary options in a Card for a cleaner look
          Card(
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                children: [
                  _tile(
                    context,
                    icon: Icons.track_changes,
                    title: 'Savings Goals',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const SavingsGoalsScreen()),
                    ),
                  ),
                  const Divider(height: 1, indent: 60),
                  _tile(
                    context,
                    icon: Icons.notifications,
                    title: 'Reminders',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const GoalNotificationsScreen()),
                    ),
                  ),
                  const Divider(height: 1, indent: 60),
                  _tile(
                    context,
                    icon: Icons.assessment_outlined,
                    title: 'Savings Reports',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const SavingsReportScreen()),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}