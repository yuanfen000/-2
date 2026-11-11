import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/ui.dart';
import '../services/cluster_service.dart';

/// Phone cluster: pick Master (runs the model) or Worker (lends this phone),
/// and pair them by scanning the worker's QR code.
class ClusterView extends StatefulWidget {
  const ClusterView({super.key});

  @override
  State<ClusterView> createState() => _ClusterViewState();
}

class _ClusterViewState extends State<ClusterView> {
  final ClusterService cluster = Get.find<ClusterService>();
  Timer? _wifiTimer;

  @override
  void initState() {
    super.initState();
    cluster.refreshWorkerStatus();
    cluster.refreshWifiAddress();
    if (cluster.role == ClusterRole.master) cluster.relocateWorkers();
    // Pick up Wi-Fi being turned on while this screen is open.
    _wifiTimer = Timer.periodic(
        const Duration(seconds: 3), (_) => cluster.refreshWifiAddress());
  }

  @override
  void dispose() {
    _wifiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: '手机集群', showBack: true),
      body: Obx(() {
        final role = cluster.role;
        return ListView(
          padding: kPagePadding,
          children: [
            const SizedBox(height: 8),
            AppSegmented<ClusterRole>(
              items: [
                (ClusterRole.off, '关闭'),
                if (ClusterService.canBeMaster) (ClusterRole.master, '主机'),
                (ClusterRole.worker, '子机'),
              ],
              selected: role,
              onChanged: cluster.setRole,
            ),
            const SizedBox(height: 16),
            if (role != ClusterRole.off && cluster.wifiAddress.value == null) ...[
              AppNotice(
                '请打开 Wi-Fi。集群里的所有手机必须连接同一个 Wi-Fi 网络。',
                icon: Icons.wifi_off_rounded,
                color: t.orange,
              ),
              const SizedBox(height: 16),
            ],
            ...switch (role) {
              ClusterRole.off => _offSection(),
              ClusterRole.master => _masterSection(context),
              ClusterRole.worker => _workerSection(context),
            },
          ],
        );
      }),
    );
  }

  List<Widget> _offSection() => [
        AppNotice(
          ClusterService.canBeMaster
              ? '一台手机跑不动的大模型，可以交给同一个 Wi-Fi 下的多台手机一起跑。\n\n'
                  '主机：你聊天用的那台手机，模型跑在它上面。\n'
                  '子机：把自己的内存借给主机用的手机。'
              : '帮另一台运行 PrivateLM 的 Android 手机跑它自己跑不动的大模型：'
                  '本机选「子机」，然后在那一台手机上扫描本机显示的二维码。',
          icon: Icons.hub_outlined,
        ),
      ];

  // ── Worker ─────────────────────────────────────────────────────────────

  List<Widget> _workerSection(BuildContext context) {
    final t = AppTokens.of(context);
    final s = cluster.worker.value;
    final qr = cluster.workerQrData;

    final Widget body;
    if (s.state == 'error') {
      body = _centered(context, [
        Icon(Icons.error_outline_rounded, size: 40, color: t.red),
        const SizedBox(height: 12),
        Text('子机已停止', style: t.bodyStrong),
        const SizedBox(height: 4),
        Text(s.error ?? '未知错误', style: t.caption, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        PillButton(label: '重试', primary: true, onPressed: cluster.startWorker),
      ]);
    } else if (s.peer != null) {
      body = _centered(context, [
        _PulsingDot(color: t.green),
        const SizedBox(height: 14),
        Text('正在为主机共享', style: t.bodyStrong.copyWith(fontSize: 18)),
        const SizedBox(height: 4),
        Text(s.peer!, style: t.caption),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: _Stat(label: '已分配', value: _gb(s.heldMb))),
          Expanded(child: _Stat(label: '启动时空闲', value: _gb(s.ramMb))),
          Expanded(child: _Stat(label: '内存速度', value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    } else if (!s.running || qr == null) {
      body = _centered(context, [
        const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(height: 16),
        Text(s.running ? '正在等待 Wi-Fi…' : '正在检测本机…', style: t.caption),
      ]);
    } else {
      body = _centered(context, [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(data: qr, size: 220, padding: EdgeInsets.zero),
        ),
        const SizedBox(height: 16),
        Text('用主机扫描这个二维码', style: t.bodyStrong),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          StatusDot(t.green, size: 8),
          const SizedBox(width: 6),
          Text('就绪 · ${cluster.wifiAddress.value}', style: t.caption),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _Stat(label: '可用内存', value: _gb(s.ramMb))),
          Expanded(child: _Stat(label: '内存速度', value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    }

    return [
      if (s.throttled) ...[
        AppNotice(
          'Android 正在给这台子机限速（只能用慢速核心），整个集群都会跟着变慢。'
          '请把 PrivateLM 的电池使用设为「不受限制」，然后把子机关掉再重新打开一次。',
          icon: Icons.speed_rounded,
          color: t.orange,
        ),
        const SizedBox(height: 8),
        const Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: '设为不受限制',
            primary: true,
            onPressed: LlamaCluster.requestBatteryUnrestricted,
          ),
        ),
        const SizedBox(height: 16),
      ],
      AppCard(padding: const EdgeInsets.fromLTRB(16, 24, 16, 20), child: body),
      SectionFootnote(ClusterService.workerStopsWithApp
          ? '请让本机保持充电、连接同一个 Wi-Fi，并让 PrivateLM 保持在前台：'
              'iOS 会暂停后台运行的应用。关掉 PrivateLM 即可停止共享。'
          : '请让本机保持充电、连接同一个 Wi-Fi，并让 PrivateLM 保持在前台：'
              '共享期间屏幕会一直亮着，因为 Android 会限制后台任务。'
              '把「手机集群」设为关闭即可停止。'),
    ];
  }

  Widget _centered(BuildContext context, List<Widget> children) =>
      Column(crossAxisAlignment: CrossAxisAlignment.center, children: children);

  // ── Master ─────────────────────────────────────────────────────────────

  List<Widget> _masterSection(BuildContext context) {
    final t = AppTokens.of(context);
    return [
      if (cluster.split.length > 1) ...[
        _SplitCard(shares: cluster.split),
        const SizedBox(height: 16),
      ],
      PrimaryButton(
        label: '扫描子机的二维码',
        icon: Icons.qr_code_scanner_rounded,
        onPressed: _scanQr,
      ),
      SectionHeader('子机（${cluster.workers.length}）'),
      if (cluster.workers.isEmpty)
        const AppGroup(children: [
          EmptyState(
            icon: Icons.devices_other_rounded,
            title: '还没有子机',
            message: '在其他手机上打开「手机集群」，选择子机，'
                '再扫描它显示的二维码。',
          ),
        ])
      else
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.workers)
            AppRow(
              icon: Icons.smartphone_rounded,
              title: w.model ?? w.name,
              subtitle: [
                w.endpoint,
                if (w.ramMb != null) '空闲 ${_gb(w.ramMb!)}',
                if (w.bandwidth != null) '${w.bandwidth!.toStringAsFixed(1)} GB/s',
              ].join(' · '),
              trailing: IconButton(
                icon: Icon(Icons.close_rounded, color: t.muted),
                tooltip: '移除',
                onPressed: () => cluster.remove(w),
              ),
            ),
        ]),
      const SectionFootnote(
        '下次加载 GGUF 模型时生效。如果模型在本机能装下，就留在本机跑，速度更快；'
        '装不下时，越快的手机分到的模型分片越多，用不上的手机就不参与。',
      ),
      const SectionHeader('其他添加方式'),
      Row(children: [
        PillButton(
          label: cluster.isScanning.value ? '搜索中…' : '查找附近',
          icon: Icons.wifi_find_rounded,
          onPressed: cluster.isScanning.value ? null : cluster.scanNearby,
        ),
        const SizedBox(width: 10),
        PillButton(
          label: '输入 IP',
          icon: Icons.keyboard_rounded,
          onPressed: () => _enterIp(context),
        ),
      ]),
      if (cluster.found.isNotEmpty) ...[
        const SizedBox(height: 12),
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.found)
            AppRow(
              icon: Icons.smartphone_rounded,
              title: w.model ?? w.name,
              subtitle: w.endpoint,
              trailing: PillButton(
                label: '添加',
                primary: true,
                onPressed: () => _report(cluster.addFound(w)),
              ),
            ),
        ]),
      ],
    ];
  }

  Future<void> _scanQr() async {
    final code = await Get.to<String>(() => const _QrScanPage());
    if (code != null) await _report(cluster.addFromQr(code));
  }

  Future<void> _enterIp(BuildContext context) async {
    final ctrl = TextEditingController();
    final input = await showAppSheet<String>(
      context,
      title: '输入子机 IP',
      subtitle: '显示在子机二维码下方',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: appInputDecoration(ctx,
                hint: '192.168.1.20:${LlamaCluster.defaultPort}'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: 16),
          PrimaryButton(label: '添加', onPressed: () => Navigator.pop(ctx, ctrl.text)),
        ],
      ),
    );
    ctrl.dispose();
    if (input != null) await _report(cluster.addManual(input));
  }

  Future<void> _report(Future<String?> adding) async {
    final error = await adding;
    if (error != null) {
      showToast('添加子机失败', error, tone: ToastTone.error);
    } else {
      showToast('已添加子机', '下次加载 GGUF 模型时生效。',
          tone: ToastTone.success);
    }
  }
}

String _gb(num mb) => '${(mb / 1024).toStringAsFixed(1)} GB';

/// How the loaded model is spread across phones: a stacked bar and legend.
class _SplitCard extends StatelessWidget {
  final List<ClusterShare> shares;
  const _SplitCard({required this.shares});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final colors = [t.accent, t.green, t.orange, const Color(0xFFAF52DE), t.red];
    final total = shares.fold<double>(0, (a, s) => a + s.mb);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('已加载模型', style: t.bodyStrong),
        const SizedBox(height: 2),
        Text('运行在 ${shares.length} 台手机上 · ${_gb(total)}', style: t.caption),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              for (var i = 0; i < shares.length; i++)
                Expanded(
                  flex: (shares[i].mb / total * 1000).round().clamp(1, 1000),
                  child: Container(
                    margin: EdgeInsets.only(right: i == shares.length - 1 ? 0 : 2),
                    color: colors[i % colors.length],
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < shares.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              StatusDot(colors[i % colors.length], size: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  shares[i].isThisPhone ? '${shares[i].name}（本机）' : shares[i].name,
                  style: t.body,
                ),
              ),
              Text('${(shares[i].mb / total * 100).round()}%', style: t.bodyStrong),
              const SizedBox(width: 10),
              SizedBox(
                width: 58,
                child: Text(_gb(shares[i].mb), textAlign: TextAlign.right, style: t.caption),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      Text(value, style: t.bodyStrong),
      const SizedBox(height: 2),
      Text(label, style: t.small, textAlign: TextAlign.center),
    ]);
  }
}

/// Live indicator for an active connection.
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Stack(alignment: Alignment.center, children: [
          Container(
            width: 24 + 32 * _c.value,
            height: 24 + 32 * _c.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
            ),
          ),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            child: const Icon(Icons.hub_rounded, size: 14, color: Colors.white),
          ),
        ]),
      ),
    );
  }
}

/// Full-screen camera that returns the first QR code it reads.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final MobileScannerController _controller =
      MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final value = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (value.isEmpty) return;
    _done = true;
    Get.back(result: value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('扫描子机二维码'),
      ),
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        const Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(
            '对准子机上的二维码',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ]),
    );
  }
}
