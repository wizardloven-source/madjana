import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../../core/providers.dart';
import '../../auth/providers/auth_provider.dart';

/// نافذة محاسبة الفوج — إيرادات / مصروفات / أرصدة افتتاحية
class FlockAccountingScreen extends ConsumerStatefulWidget {
  final FlockModel flock;

  const FlockAccountingScreen({super.key, required this.flock});

  @override
  ConsumerState<FlockAccountingScreen> createState() =>
      _FlockAccountingScreenState();
}

class _FlockAccountingScreenState
    extends ConsumerState<FlockAccountingScreen> {
  bool _loading = true;
  DateTime _fromDate = DateTime(2020, 1, 1);
  DateTime _toDate = DateTime.now();

  // ── بيانات محمّلة ──
  List<EggProductionModel> _eggs = [];
  List<MortalityModel> _mortality = [];
  List<FeedConsumptionModel> _feed = [];
  List<DispatchModel> _dispatches = [];
  List<PaymentModel> _payments = [];
  List<MedicationModel> _medications = [];
  OpeningBalanceModel? _opening;

  String get _farmId => ref.read(authProvider).currentUser?.farmId ?? '';

  @override
  void initState() {
    super.initState();
    // الافتراضي: من تاريخ بدء القطيع
    _fromDate = widget.flock.startDate;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        ref.read(eggProductionRepositoryProvider).getAllRecords(
              farmId: _farmId,
              fromDate: _fromDate,
              toDate: _toDate,
            ),
        ref.read(mortalityRepositoryProvider).getAllRecords(
              farmId: _farmId,
              fromDate: _fromDate,
              toDate: _toDate,
            ),
        ref.read(feedRepositoryProvider).getAllConsumption(
              farmId: _farmId,
              fromDate: _fromDate,
              toDate: _toDate,
            ),
        ref.read(dispatchRepositoryProvider).getAll(
              farmId: _farmId,
              fromDate: _fromDate,
              toDate: _toDate,
            ),
        ref.read(paymentRepositoryProvider).getAll(
              farmId: _farmId,
              fromDate: _fromDate,
              toDate: _toDate,
            ),
        ref.read(medicationRepositoryProvider).getAll(
              farmId: _farmId,
              fromDate: _fromDate,
              toDate: _toDate,
            ),
        ref
            .read(openingBalanceRepositoryProvider)
            .getForFlock(_farmId, widget.flock.id),
      ]);
      if (!mounted) return;
      setState(() {
        _eggs = results[0] as List<EggProductionModel>;
        _mortality = results[1] as List<MortalityModel>;
        _feed = results[2] as List<FeedConsumptionModel>;
        _dispatches = results[3] as List<DispatchModel>;
        _payments = results[4] as List<PaymentModel>;
        _medications = results[5] as List<MedicationModel>;
        _opening = results[6] as OpeningBalanceModel?;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('خطأ في التحميل: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _fromDate : _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _fromDate = picked;
        } else {
          _toDate = picked;
        }
      });
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final flockId = widget.flock.id;
    final currency = ref.watch(currencyProvider).value ?? '\$';

    // ── تصفية حسب القطيع ──
    final flockEggs =
        _eggs.where((e) => e.flockId == flockId).toList();
    final flockMortality =
        _mortality.where((m) => m.flockId == flockId).toList();
    final flockFeed =
        _feed.where((f) => f.flockId == flockId).toList();
    final flockDispatches =
        _dispatches.where((d) => d.flockId == flockId).toList();
    final flockMeds =
        _medications.where((m) => m.flockId == flockId).toList();
    final dispatchIds =
        flockDispatches.map((d) => d.id).whereType<String>().toSet();
    final flockPayments =
        _payments.where((p) => p.dispatchId != null && dispatchIds.contains(p.dispatchId)).toList();

    // ── حسابات الإنتاج ──
    final totalProduced = flockEggs.fold<int>(0, (s, e) => s + e.totalEggs);
    final totalCartons = flockEggs.fold<int>(0, (s, e) => s + e.cartons);
    final totalMortality = flockMortality.fold<int>(0, (s, m) => s + m.count);
    final totalFeedKg = flockFeed.fold<double>(0, (s, f) => s + f.quantityKg);
    final totalMeds = flockMeds.length;

    // ── حسابات التخريج والمبيعات ──
    final dispatchedCartons = flockDispatches.fold<int>(0, (s, d) => s + d.cartons);
    final dispatchedEggs = flockDispatches.fold<int>(0, (s, d) => s + d.totalEggs);
    final totalDue = flockPayments.fold<double>(0, (s, p) => s + p.totalDue);
    final totalPaid = flockPayments.fold<double>(0, (s, p) => s + p.amountPaid);
    final outstanding = totalDue - totalPaid;

    // ── أرصدة افتتاحية ──
    final ob = _opening;
    final obProduced = ob?.eggsProduced ?? 0;
    final obDispatched = ob?.eggsDispatched ?? 0;
    final obMortality = ob?.mortalityCount ?? 0;
    final obFeedKg = ob?.feedConsumedKg ?? 0.0;
    final obRevenues = ob?.totalRevenues ?? 0.0;
    final obPayments = ob?.totalPayments ?? 0.0;

    // ── المجاميع الكليّة ( CURRENT + OPENING ) ──
    final grandProduced = totalProduced + obProduced;
    final grandDispatched = dispatchedEggs + obDispatched;
    final grandMortality = totalMortality + obMortality;
    final grandFeedKg = totalFeedKg + obFeedKg;
    final grandRevenues = totalDue + obRevenues;
    final grandPaid = totalPaid + obPayments;
    final grandOutstanding = grandRevenues - grandPaid;

    return Scaffold(
      appBar: AppBar(
        title: Text('محاسبة القطيع — ${widget.flock.breed}'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Row(children: [
              OutlinedButton(
                onPressed: () => _pickDate(isFrom: true),
                child: Text(
                    '${_fromDate.year}/${_fromDate.month}/${_fromDate.day}'),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.arrow_right_alt, size: 16),
              ),
              OutlinedButton(
                onPressed: () => _pickDate(isFrom: false),
                child: Text(
                    '${_toDate.year}/${_toDate.month}/${_toDate.day}'),
              ),
            ]),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ─── معلومات القطيع ───
                  _InfoHeader(
                    flock: widget.flock,
                    effectiveCount: widget.flock.effectiveCount(
                      _mortality
                              .where((m) => m.flockId == widget.flock.id)
                              .fold<int>(0, (s, m) => s + m.count) +
                          (_opening?.mortalityCount ?? 0),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ─── الأرصدة الافتتاحية (إن وُجدت) ───
                  if (ob != null) ...[
                    _SectionTitle('الأرصدة الافتتاحية (قطيع قديم)'),
                    const SizedBox(height: 8),
                    _OpeningBalanceCard(opening: ob, currency: currency),
                    const SizedBox(height: 20),
                  ],

                  // ─── الإنتاج والمخزون ───
                  _SectionTitle(ob != null
                      ? 'الإنتاج والمخزون (تراكمي شامل الأرصدة)'
                      : 'الإنتاج والمخزون (الفترة الحالية)'),
                  const SizedBox(height: 8),
                  _StatsRow(
                    children: [
                      _StatTile(
                          'بيض منتج',
                          ob != null ? '$grandProduced' : '$totalProduced',
                          Icons.egg, Colors.orange),
                      _StatTile(
                          'كنار',
                          ob != null
                              ? '$totalCartons (+${obProduced ~/ AppConstants.eggsPerCarton} كرتون أرصدة)'
                              : '$totalCartons',
                          Icons.inventory_2, Colors.brown),
                      _StatTile(
                          'نفوق',
                          ob != null ? '$grandMortality' : '$totalMortality',
                          Icons.warning_amber, Colors.red),
                      _StatTile(
                          'علف',
                          '${(ob != null ? grandFeedKg : totalFeedKg).toStringAsFixed(1)} كغ',
                          Icons.grass,
                          Colors.green),
                      if (totalMeds > 0)
                        _StatTile('سجلات علاج', '$totalMeds',
                            Icons.medical_services,
                            Colors.purple),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // ─── التخريج والمبيعات ───
                  _SectionTitle('التخريج والمبيعات (الفترة الحالية)'),
                  const SizedBox(height: 8),
                  _StatsRow(
                    children: [
                      _StatTile('كراتين مخرّجة', '$dispatchedCartons',
                          Icons.local_shipping, Colors.blue),
                      _StatTile('بيض مخرّج',
                          ob != null ? '$grandDispatched' : '$dispatchedEggs',
                          Icons.egg_alt, Colors.teal),
                      _StatTile(
                          'المستحق',
                          '$currency ${totalDue.toStringAsFixed(2)}',
                          Icons.receipt_long,
                          Colors.indigo),
                      _StatTile(
                          'المحصّل',
                          '$currency ${totalPaid.toStringAsFixed(2)}',
                          Icons.paid,
                          Colors.green),
                      _StatTile(
                          'المستحق عليه',
                          '$currency ${outstanding.toStringAsFixed(2)}',
                          Icons.hourglass_top,
                          outstanding > 0 ? Colors.orange : Colors.green),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // ─── المحصّل + الأرصدة الافتتاحية ───
                  if (ob != null) ...[
                    _SectionTitle('الإيرادات التراكمية (شاملة الأرصدة)'),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.green.shade50,
                            Colors.green.shade100,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        border:
                            Border.all(color: Colors.green.shade300),
                      ),
                      child: Column(
                        children: [
                          _SummaryRow(
                            'إيرادات الأرصدة الافتتاحية',
                            '$currency ${obRevenues.toStringAsFixed(2)}',
                          ),
                          const Divider(),
                          _SummaryRow(
                            'إيرادات الفترة الحالية',
                            '$currency ${totalDue.toStringAsFixed(2)}',
                          ),
                          const Divider(),
                          _SummaryRow(
                            'الإجمالي',
                            '$currency ${grandRevenues.toStringAsFixed(2)}',
                            bold: true,
                          ),
                          const Divider(),
                          _SummaryRow(
                            'المدفوعات الأرصدة',
                            '$currency ${obPayments.toStringAsFixed(2)}',
                          ),
                          const Divider(),
                          _SummaryRow(
                            'المدفوعات الفترية',
                            '$currency ${totalPaid.toStringAsFixed(2)}',
                          ),
                          const Divider(),
                          _SummaryRow(
                            'المدفوعات الإجمالية',
                            '$currency ${grandPaid.toStringAsFixed(2)}',
                            bold: true,
                          ),
                          const Divider(),
                          _SummaryRow(
                            'المتبقي',
                            '$currency ${grandOutstanding.toStringAsFixed(2)}',
                            bold: true,
                            highlight: grandOutstanding > 0,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // ─── جدول التفاصيل ───
                  _SectionTitle('تفاصيل المبيعات'),
                  const SizedBox(height: 8),
                  if (flockDispatches.isEmpty)
                    const Card(
                        child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('لا توجد تخريجات في هذه الفترة'),
                    ))
                  else
                    Card(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('التاريخ')),
                            DataColumn(label: Text('الزبون')),
                            DataColumn(label: Text('كراتين')),
                            DataColumn(label: Text('صحون')),
                            DataColumn(label: Text('الحالة')),
                          ],
                          rows: flockDispatches.map((d) {
                            final payment = _payments.firstWhere(
                              (p) => p.dispatchId == d.id,
                              orElse: () => PaymentModel(
                                farmId: '',
                                customerId: '',
                                date: d.date,
                                pricePerCarton: 0,
                                totalDue: 0,
                                amountPaid: 0,
                                paymentMethod: PaymentMethod.cash,
                                managerId: '',
                              ),
                            );
                            return DataRow(cells: [
                              DataCell(Text(
                                  '${d.date.year}/${d.date.month}/${d.date.day}')),
                              DataCell(Text(
                                d.customerId.length <= 8
                                    ? d.customerId
                                    : d.customerId.substring(0, 8),
                              )),
                              DataCell(Text('${d.cartons}')),
                              DataCell(Text('${d.trays}')),
                              DataCell(Chip(
                                label: Text(
                                  payment.isPaid ? 'مسدّد' : 'مستحق',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                backgroundColor: payment.isPaid
                                    ? Colors.green.shade100
                                    : Colors.orange.shade100,
                                padding: EdgeInsets.zero,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              )),
                            ]);
                          }).toList(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

// ─── ودجت عنوان القطيع ───
class _InfoHeader extends StatelessWidget {
  final FlockModel flock;
  final int effectiveCount;
  const _InfoHeader({required this.flock, required this.effectiveCount});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ended = flock.status == FlockStatus.depleted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              ended ? Icons.history : Icons.pets,
              size: 32,
              color: ended ? Colors.orange : theme.colorScheme.primary,
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  flock.breed,
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  'العمر: ${flock.ageLabel}  |  '
                  'الأولي: ${flock.initialCount}  |  '
                  'الحالي: $effectiveCount  |  '
                  'العنابر: ${flock.sectionsCount}',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
            const Spacer(),
            Chip(
              label: Text(ended ? 'منتهي' : 'نشط'),
              backgroundColor:
                  ended ? Colors.grey.shade200 : Colors.green.shade100,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── عنوان قسم ───
class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

// ─── صفوف الإحصائيات ───
class _StatsRow extends StatelessWidget {
  final List<Widget> children;
  const _StatsRow({required this.children});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: children,
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatTile(this.label, this.value, this.icon, this.color);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Container(
        width: 140,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── بطاقة الأرصدة الافتتاحية ───
class _OpeningBalanceCard extends StatelessWidget {
  final OpeningBalanceModel opening;
  final String currency;

  const _OpeningBalanceCard({required this.opening, required this.currency});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.shade300),
        ),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _OBItem('بيض منتج', '${opening.eggsProduced}'),
            _OBItem('بيض مخرّج', '${opening.eggsDispatched}'),
            _OBItem('نفوق', '${opening.mortalityCount}'),
            _OBItem('علف', '${opening.feedConsumedKg.toStringAsFixed(1)} كغ'),
            _OBItem('إيرادات',
                '$currency ${opening.totalRevenues.toStringAsFixed(2)}'),
            _OBItem('مدفوعات',
                '$currency ${opening.totalPayments.toStringAsFixed(2)}'),
            if (opening.sections.isNotEmpty) ...[
              const SizedBox(width: 8),
              _OBItem('عدد العنابر', '${opening.sections.length}'),
            ],
          ],
        ),
      ),
    );
  }
}

class _OBItem extends StatelessWidget {
  final String label;
  final String value;
  const _OBItem(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }
}

// ─── صف ملخّص ───
class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final bool highlight;

  const _SummaryRow(
    this.label,
    this.value, {
    this.bold = false,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              color: highlight ? Colors.red : null,
            ),
          ),
        ],
      ),
    );
  }
}
