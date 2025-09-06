import 'package:flutter/material.dart';
import 'stock_forecast_screen.dart';
import 'commodity_forecast_screen.dart';
import 'investment_suggestion_screen.dart';
import 'community_screen.dart';
import 'news_screen.dart';

class InvestmentHome extends StatelessWidget {
  const InvestmentHome({super.key});

  // The new "hero" component for the main feature.
  Widget _buildSuggestionCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => const InvestmentSuggestionScreen())),
      child: Card(
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
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
              Icon(Icons.lightbulb_outline, color: cs.onPrimary, size: 40),
              const SizedBox(height: 12),
              Text(
                'Investment Suggestion',
                style: textTheme.headlineSmall?.copyWith(
                  color: cs.onPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Goal-based personalized plans',
                style: textTheme.bodyMedium
                    ?.copyWith(color: cs.onPrimary.withOpacity(0.9)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // A new, compact tile for the grid layout.
  Widget _buildGridItem(BuildContext context,
      {required IconData icon,
        required String title,
        required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Card(
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        color: cs.surfaceVariant.withOpacity(0.5),
        elevation: 0,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 32, color: cs.primary),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
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
        title: const Text('Investment Management'),
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
            // Main Feature Card
            _buildSuggestionCard(context),

            const SizedBox(height: 24),

            // Sub-header for the grid
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: Text(
                'Market Tools & Community',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: Colors.black54),
              ),
            ),

            const SizedBox(height: 12),

            // Grid for secondary features
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.1,
              children: [
                _buildGridItem(
                  context,
                  icon: Icons.show_chart,
                  title: 'Stock Forecast',
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const StockForecastScreen())),
                ),
                _buildGridItem(
                  context,
                  icon: Icons.auto_graph,
                  title: 'Commodities',
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CommodityForecastScreen())),
                ),
                _buildGridItem(
                  context,
                  icon: Icons.newspaper_outlined,
                  title: 'Market News',
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const NewsScreen())),
                ),
                _buildGridItem(
                  context,
                  icon: Icons.forum_outlined,
                  title: 'Community Q&A',
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const CommunityScreen())),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}