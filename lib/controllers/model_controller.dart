import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../services/download_service.dart';
import '../services/gguf_metadata.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';
import '../services/hive_service.dart';
import '../services/app_log_service.dart';
import '../services/device_info_service.dart';
import '../models/ai_model.dart';
import '../core/constants.dart';
import '../core/ui.dart';
import '../services/cluster_service.dart';
import 'settings_controller.dart';

enum _ModelLoadAction { cancel, unloadAndContinue, continueLoad }

/// A model file found by scanning a folder the user picked.
class FolderModelFile {
  final String uri;
  final String name;
  final int size;
  const FolderModelFile(
      {required this.uri, required this.name, required this.size});
}

class ModelController extends GetxController {
  final DownloadService _download = Get.find<DownloadService>();
  final LocalImageService _localImage = Get.find<LocalImageService>();
  final InferenceService _inference = Get.find<InferenceService>();
  final HiveService _hive = Get.find<HiveService>();
  final SettingsController _settings = Get.find<SettingsController>();

  static const _customModelsKey = 'custom_url_models';
  static const _androidImportChannel =
      MethodChannel('com.aichat.ai_chat/model_import');

  Map<String, DownloadProgress> get activeDownloads =>
      _download.activeDownloads;

  final availableModels = <AiModel>[].obs;
  final downloadedFiles = <String>[].obs;

  /// Vision projector (mmproj) files on disk. They're hidden from the model
  /// list but tell us whether a vision model can read images yet.
  final visionFiles = <String>{}.obs;
  final isImporting = false.obs;
  final customModels = <AiModel>[].obs;
  final fileSizes = <String, int>{}.obs;
  final modelScope = 'local'.obs;
  final localFilter = ''.obs;
  final importFileName = ''.obs;
  final importStatus = ''.obs;
  final importCopiedBytes = 0.obs;
  final importTotalBytes = 0.obs;
  final importBytesPerSecond = 0.0.obs;
  final sortSmallestFirst = true.obs;
  final externalDownloadId = Rx<int?>(null);

  void toggleSort() {
    sortSmallestFirst.value = !sortSmallestFirst.value;
  }

  /// Apple Neural Engine (Core ML) models are only usable on Apple devices.
  static bool get supportsAppleNpu => Platform.isIOS || Platform.isMacOS;

  static const localFilters = [
    'general',
    'image',
    'uncensored',
    'vision',
    'npu'
  ];

  List<AiModel> get displayedModels {
    // Loading a model doesn't move it: the list keeps its normal order and
    // the loaded model is marked in place.
    final models = [...availableModels];
    models.sort((a, b) {
      final aDownloaded = isDownloaded(a.filename);
      final bDownloaded = isDownloaded(b.filename);
      if (aDownloaded != bDownloaded) return aDownloaded ? -1 : 1;

      if (sortSmallestFirst.value) {
        final aBytes = _knownModelBytes(a);
        final bBytes = _knownModelBytes(b);
        if (aBytes > 0 && bBytes > 0 && aBytes != bBytes) {
          return aBytes.compareTo(bBytes);
        }
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return models;
  }

  List<AiModel> get filteredDisplayedModels {
    final filter =
        localFilter.value.isEmpty ? defaultLocalFilter : localFilter.value;
    final filtered = displayedModels.where((model) {
      switch (filter) {
        case 'uncensored':
          return isUncensoredModel(model);
        case 'vision':
          return isVisionModel(model);
        case 'image':
          return isImageModel(model);
        case 'npu':
          return isNpuModel(model);
        case 'general':
        default:
          return isGeneralModel(model);
      }
    }).toList();
    // The filter's recommended pick goes first; the rest keep their order
    // (List.sort isn't stable, so partition instead).
    return [
      ...filtered.where((m) => m.recommendedFor.contains(filter)),
      ...filtered.where((m) => !m.recommendedFor.contains(filter)),
    ];
  }

  String get defaultLocalFilter => 'general';

  double get importProgress => importTotalBytes.value <= 0
      ? 0.0
      : (importCopiedBytes.value / importTotalBytes.value)
          .clamp(0.0, 1.0)
          .toDouble();

  int get downloadedCount => downloadedFiles.length;

  String get activeLocalModelName => _inference.loadedModelName.value;

  @override
  void onInit() {
    super.onInit();
    _loadCustomModels();
    availableModels.value = AppConstants.availableModels
        .map((m) => AiModel.fromMap(m))
        // Core ML (Apple NPU) models only run on iOS/macOS.
        .where((m) => supportsAppleNpu || !isNpuModel(m))
        .toList()
      ..addAll(customModels);
    refreshDownloaded();
  }

  void _loadCustomModels() {
    final raw =
        _hive.getSetting<List>(_customModelsKey, defaultValue: []) ?? [];
    customModels.value = raw
        .whereType<Map>()
        .map((m) => AiModel.fromMap(Map<String, String>.from(m)))
        .toList();
  }

  Future<void> _saveCustomModels() async {
    await _hive.setSetting(
      _customModelsKey,
      customModels.map((m) => m.toMap()).toList(),
    );
  }

  Future<void> refreshDownloaded() async {
    await _deletePartialImports();
    final allFiles = await _download.getDownloadedModels();
    visionFiles
      ..clear()
      ..addAll(allFiles.where(_isVisionProjectorFile));
    final files =
        allFiles.where((file) => !_isAuxiliaryImageFile(file)).toList();
    downloadedFiles.value = files;
    for (final file in files) {
      fileSizes[file] = await _download.getModelSize(file);
    }

    // Add any downloaded files that are not in availableModels
    final existingFilenames = availableModels.map((m) {
      if (m.filename.toLowerCase().endsWith('.zip')) {
        return m.filename.substring(0, m.filename.length - 4);
      }
      return m.filename;
    }).toSet();
    for (final file in files) {
      if (!existingFilenames.contains(file)) {
        // An imported copy of a catalogue vision model (any capitalisation,
        // e.g. the original Hugging Face name) keeps the catalogue's vision
        // file, so images work after one in-app download.
        final known = _catalogVisionMatch(file);
        if (known != null) {
          availableModels.add(known.copyWith(
            filename: file,
            url: '',
            size: _formatModelSize(file),
            description: '已导入 · 配合视觉文件可读取图片',
            isImported: true,
          ));
          continue;
        }
        final lower = file.toLowerCase();
        final runtime = AiModel.runtimeFromFilename(file);
        final isLiteRt = runtime == AiModel.runtimeLiteRt;
        final isVision = isLiteRt && AiModel.hasVisionMarker(lower);

        availableModels.add(AiModel(
          name: file,
          filename: file,
          url: '',
          size: _formatModelSize(file),
          description: '已从本地存储导入',
          template: isLiteRt ? 'litert' : 'chatml',
          runtime: runtime,
          isImported: true,
          isVision: isVision,
        ));
      }
    }

    // Remove any imported models that are no longer downloaded
    availableModels.removeWhere(
        (model) => model.isImported && !files.contains(model.filename));

    if (localFilter.value.isEmpty) {
      localFilter.value = defaultLocalFilter;
    }
  }

  bool isDownloaded(String filename) {
    if (filename.toLowerCase().endsWith('.zip')) {
      return downloadedFiles
          .contains(filename.substring(0, filename.length - 4));
    }
    return downloadedFiles.contains(filename);
  }

  bool _isVisionProjectorFile(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.gguf') && lower.contains('mmproj');
  }

  /// Catalogue vision model whose file this is, matched case-insensitively
  /// on our filename or the original download name.
  AiModel? _catalogVisionMatch(String file) {
    final lower = file.toLowerCase();
    for (final m in AppConstants.availableModels) {
      if ((m['mmproj_filename'] ?? '').isEmpty) continue;
      final urlName = Uri.tryParse(m['url'] ?? '')?.pathSegments.last ?? '';
      if ((m['filename'] ?? '').toLowerCase() == lower ||
          urlName.toLowerCase() == lower) {
        return AiModel.fromMap(m);
      }
    }
    return null;
  }

  /// The model's vision file is on disk, so images can be used once loaded.
  bool isVisionFileReady(AiModel model) =>
      model.hasVisionProjector && visionFiles.contains(model.mmprojFilename);

  /// Size of a model's vision file from the catalogue ("986 MB"), if known.
  String visionFileSizeLabel(AiModel model) {
    for (final m in AppConstants.availableModels) {
      if (m['mmproj_filename'] != model.mmprojFilename) continue;
      final match = RegExp(r'\+\s*([\d.]+\s*(?:MB|GB))', caseSensitive: false)
          .firstMatch(m['size'] ?? '');
      return match?.group(1) ?? '';
    }
    return '';
  }

  /// Downloads just the vision file for a model that's already on disk.
  Future<void> downloadVisionFile(AiModel model) async {
    if (!model.hasVisionProjector || model.mmprojUrl.isEmpty) return;
    if (isDownloadingModel(model.mmprojFilename)) return;
    await _downloadVisionFile(model);
  }

  bool _isAuxiliaryImageFile(String filename) {
    final lower = filename.toLowerCase();
    // GGUF vision projectors ride along with their model; never list or
    // load them as models of their own.
    if (lower.endsWith('.gguf') && lower.contains('mmproj')) return true;
    return lower == 'taesd.safetensors' ||
        lower.startsWith('taesd-') ||
        lower.startsWith('taesd_') ||
        lower == 'diffusion_pytorch_model.safetensors' ||
        lower.endsWith('.vae.safetensors') ||
        lower.startsWith('vae-') ||
        lower.startsWith('vae_');
  }

  bool _isIncompleteCatalogFile(AiModel model, int fileBytes) {
    if (model.url.trim().isEmpty || model.isImported || fileBytes <= 0) {
      return false;
    }
    final expectedBytes = _declaredModelBytes(model);
    if (expectedBytes <= 0) return false;
    // Relax threshold to 85% to comfortably accommodate HuggingFace decimal-scaled catalog sizes
    // and rounded metadata sizes (e.g. 770.3MB listed as 0.8GB) while still blocking failed downloads.
    return fileBytes < (expectedBytes * 0.85).round();
  }

  bool get isDownloading => _download.isDownloadingAny;

  String get lastLoadedModelName =>
      _hive.getSetting<String>(AppConstants.keyLocalModelName) ?? '';

  bool get canLoadLastModel =>
      lastLoadedModelName.isNotEmpty && isDownloaded(lastLoadedModelName);

  DownloadProgress? getDownloadProgress(String filename) =>
      _download.activeDownloads[filename];

  bool isDownloadingModel(String filename) =>
      _download.activeDownloads.containsKey(filename);

  void setLocalFilter(String filter) {
    if (filter == 'npu' && !supportsAppleNpu) return;
    if (localFilters.contains(filter)) {
      localFilter.value = filter;
    }
  }

  /// Can read images: LiteRT vision models, or GGUF models that come with a
  /// vision projector (mmproj) file.
  bool isVisionModel(AiModel model) {
    if (model.hasVisionProjector) return true;
    if (!isLiteRtModel(model)) return false;
    final lower =
        '${model.name} ${model.filename} ${model.description}'.toLowerCase();
    return model.isVision || AiModel.hasVisionMarker(lower);
  }

  bool isUncensoredModel(AiModel model) {
    return AppConstants.isUncensoredModelName(
      '${model.name} ${model.filename} ${model.description}',
    );
  }

  bool isImageModel(AiModel model) {
    final lower = model.filename.toLowerCase();
    return model.runtime == AiModel.runtimeSd ||
        lower.endsWith('.safetensors') ||
        lower.endsWith('.coreml') ||
        lower.endsWith('.mlpackage') ||
        lower.endsWith('.mlmodelc') ||
        model.template == 'sd';
  }

  bool isLiteRtModel(AiModel model) {
    return model.runtime == AiModel.runtimeLiteRt ||
        model.filename.toLowerCase().endsWith('.litertlm');
  }

  bool isLlamaModel(AiModel model) {
    return model.runtime == AiModel.runtimeLlama ||
        model.filename.toLowerCase().endsWith('.gguf');
  }

  bool isGeneralModel(AiModel model) =>
      !isVisionModel(model) &&
      !isUncensoredModel(model) &&
      !isImageModel(model) &&
      !isNpuModel(model);

  bool isNpuModel(AiModel model) {
    final lower = model.filename.toLowerCase();
    return lower.endsWith('.mlmodelc') ||
        lower.endsWith('.mlpackage') ||
        lower.contains('coreml');
  }

  String modelSizeLabel(AiModel model) {
    final bytes = fileSizes[model.filename] ?? 0;
    if (bytes > 0) return DownloadService.formatBytes(bytes);
    return model.size;
  }

  int _knownModelBytes(AiModel model) {
    final detected = fileSizes[model.filename] ?? 0;
    if (detected > 0) return detected;
    return _declaredModelBytes(model);
  }

  int _declaredModelBytes(AiModel model) {
    final match = RegExp(r'([\d.]+)\s*(GB|MB)', caseSensitive: false)
        .firstMatch(model.size);
    if (match == null) return 0;
    final value = double.tryParse(match.group(1) ?? '') ?? 0;
    final unit = (match.group(2) ?? '').toUpperCase();
    // Catalog sizes follow Hugging Face (decimal: 1 GB = 10^9 bytes).
    // Reading them as binary inflated every expectation by ~7% and flagged
    // complete downloads as incomplete.
    if (unit == 'GB') return (value * 1000 * 1000 * 1000).round();
    if (unit == 'MB') return (value * 1000 * 1000).round();
    return 0;
  }

  String _formatModelSize(String filename) {
    final bytes = fileSizes[filename] ?? 0;
    if (bytes <= 0) return '本地文件';
    return DownloadService.formatBytes(bytes);
  }

  Future<void> downloadModel(AiModel model) async {
    if (externalDownloadId.value != null &&
        importFileName.value == model.filename) {
      showToast('正在下载',
          '该模型正在下载到「下载」文件夹，请先等它下载完成。',
          tone: ToastTone.warning);
      return;
    }
    try {
      // Vision models need their projector too; fetch both together.
      if (model.hasVisionProjector &&
          model.mmprojUrl.isNotEmpty &&
          !await _download.isModelDownloaded(model.mmprojFilename) &&
          !_download.activeDownloads.containsKey(model.mmprojFilename)) {
        unawaited(_downloadVisionFile(model));
      }
      await _download.downloadModel(
        url: model.url,
        filename: model.filename,
      );
      await refreshDownloaded();
    } catch (e) {
      Get.find<AppLogService>().error('Model download failed', details: e);
      showToast('下载失败', '$e', tone: ToastTone.error);
    }
  }

  /// Copies a downloaded model (and its vision file, if any) from app
  /// storage to the phone's public Downloads folder.
  Future<void> saveToDownloads(AiModel model) async {
    final files = [
      model.filename,
      if (model.hasVisionProjector && isVisionFileReady(model))
        model.mmprojFilename,
    ];
    final saved = <String>[];
    for (final name in files) {
      if (activeDownloads.containsKey('save:$name')) continue;
      try {
        final path = await _download.modelPath(name);
        final result = await _androidImportChannel.invokeMethod<String>(
            'saveToDownloads', {'path': path, 'name': name});
        if (result != null) saved.add(result);
      } on PlatformException catch (e) {
        Get.find<AppLogService>().error('Save to Downloads failed', details: e);
        showToast('未保存', e.message ?? '无法保存 $name。',
            tone: ToastTone.error);
        return;
      }
    }
    if (saved.isNotEmpty) {
      showToast(
        '已保存到下载',
        saved.length == 1
            ? '${saved.first} 已放入「下载」文件夹。'
            : '${saved.length} 个文件（模型 + 视觉文件）已放入「下载」文件夹。',
        tone: ToastTone.success,
      );
    }
  }

  /// Background download of a GGUF vision model's projector file.
  Future<void> _downloadVisionFile(AiModel model) async {
    try {
      await _download.downloadModel(
          url: model.mmprojUrl, filename: model.mmprojFilename);
    } catch (e) {
      Get.find<AppLogService>()
          .error('Vision file download failed', details: e);
    }
  }

  Future<void> downloadModelToDownloads(AiModel model) async {
    if (model.url.trim().isEmpty) {
      showToast('无法下载', '这个模型没有下载链接。',
          tone: ToastTone.warning);
      return;
    }

    if (!Platform.isAndroid) {
      showToast(
        '仅支持 Android',
        '在此平台上请用应用内的下载按钮，或导入本地模型。',
        tone: ToastTone.info,
      );
      return;
    }

    // Both downloads report progress under the same filename; running them
    // together mixes up their progress.
    if (isDownloadingModel(model.filename)) {
      showToast('正在下载',
          '请先等应用内该模型的下载完成。',
          tone: ToastTone.warning);
      return;
    }

    try {
      isImporting.value = true;
      importFileName.value = model.filename;
      importStatus.value = 'Starting download...';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;

      final result =
          await _androidImportChannel.invokeMapMethod<String, dynamic>(
        'downloadToDownloads',
        {'url': model.url, 'filename': model.filename},
      );
      externalDownloadId.value = result?['downloadId'] as int?;
      final filename = result?['filename'] as String? ?? model.filename;
      showToast(
        '已开始下载',
        '$filename 正在下载到「下载」文件夹。',
        tone: ToastTone.info,
      );
    } on PlatformException catch (e) {
      isImporting.value = false;
      externalDownloadId.value = null;
      Get.find<AppLogService>().error(
        'Download to Downloads failed',
        details: '${e.code}: ${e.message}',
      );
      showToast('下载失败', e.message ?? e.code, tone: ToastTone.error);
    } catch (e) {
      isImporting.value = false;
      externalDownloadId.value = null;
      Get.find<AppLogService>()
          .error('Download to Downloads failed', details: e);
      showToast('下载失败', '$e', tone: ToastTone.error);
    }
  }

  Future<void> cancelExternalDownload() async {
    final id = externalDownloadId.value;
    if (id != null) {
      try {
        await _androidImportChannel
            .invokeMethod('cancelDownloadToDownloads', {'downloadId': id});
      } catch (e) {
        Get.find<AppLogService>().error('Cancel download failed', details: e);
      }
      externalDownloadId.value = null;
      isImporting.value = false;
      importStatus.value = 'Download cancelled';
    }
  }

  /// Android's DownloadManager offers no pause API, so stopping there cancels
  /// the download; elsewhere progress is kept and the next download resumes.
  bool get canPauseDownloads => !Platform.isAndroid;

  void pauseDownload(String filename) {
    _download.pauseDownload(filename);
  }

  /// Removes a custom model entry added from a URL in an earlier version,
  /// cancelling any download and deleting any partial or complete file.
  Future<void> removeCustomModel(AiModel model) async {
    if (_download.activeDownloads.containsKey(model.filename)) {
      _download.pauseDownload(model.filename);
    }
    if (_inference.loadedModelName.value == model.filename) {
      await _inference.unloadModel();
    }
    await _download.deleteModel(model.filename);
    customModels.removeWhere((m) => m.filename == model.filename);
    availableModels
        .removeWhere((m) => m.isCustom && m.filename == model.filename);
    await _saveCustomModels();
    await refreshDownloaded();
  }

  Future<void> deleteModel(String filename) async {
    final model =
        availableModels.firstWhereOrNull((m) => m.filename == filename);
    if (model != null && model.hasVisionProjector) {
      try {
        await _download.deleteModel(model.mmprojFilename);
      } catch (_) {}
    }
    await _download.deleteModel(filename);
    await refreshDownloaded();
    // Unload if this was the active model
    if (_inference.loadedModelName.value == filename) {
      await _inference.unloadModel();
    }
  }

  Future<void> loadModel(String filename) async {
    if (_inference.isLoadingModel.value) {
      showToast('模型加载中', '另一个模型正在加载。',
          tone: ToastTone.warning);
      return;
    }
    final path = await _download.modelPath(filename);
    final model =
        availableModels.firstWhereOrNull((m) => m.filename == filename);
    if (_isAuxiliaryImageFile(filename)) {
      showToast(
        '辅助文件',
        '$filename 是其他模型使用的辅助文件，不能单独加载。',
        tone: ToastTone.info,
      );
      return;
    }
    final isLiteRt = filename.toLowerCase().endsWith('.litertlm') ||
        model?.runtime == AiModel.runtimeLiteRt;
    // Switching runtimes (LiteRT <-> GGUF) only needs the current engine
    // unloaded first; the load sheet below offers "Unload & continue".
    final fileBytes = await _modelFileBytes(filename, path, model);
    if (model != null && _isIncompleteCatalogFile(model, fileBytes)) {
      final actual = DownloadService.formatBytes(fileBytes);
      Get.find<AppLogService>().error(
        'Incomplete model file blocked',
        details: '$filename is $actual, expected about ${model.size}',
      );
      showToast(
        '模型文件不完整',
        '$filename 只有 $actual，请删除后重新下载。',
        tone: ToastTone.error,
        duration: const Duration(seconds: 6),
      );
      return;
    }
    if (filename.toLowerCase().endsWith('.safetensors') &&
        !await _hasValidSafetensorsHeader(path)) {
      Get.find<AppLogService>().error(
        'Corrupt safetensors file blocked',
        details: '$filename failed safetensors header validation',
      );
      showToast(
        '模型文件已损坏',
        '$filename 下载结果异常，请删除后重新下载。',
        tone: ToastTone.error,
        duration: const Duration(seconds: 6),
      );
      return;
    }
    if (isLiteRt && !await _hasLikelyValidLiteRtFile(path, fileBytes)) {
      Get.find<AppLogService>().error(
        'Corrupt LiteRT model file blocked',
        details: '$filename failed LiteRT file validation; size=$fileBytes',
      );
      showToast(
        '模型文件已损坏',
        '$filename 不是有效的 LiteRT-LM 文件，请删除后重新下载。',
        tone: ToastTone.error,
        duration: const Duration(seconds: 6),
      );
      return;
    }
    // The phone cluster splits GGUF models only (llama.cpp); a LiteRT model
    // always runs on this phone, so say so instead of silently ignoring the
    // workers.
    if (isLiteRt &&
        Get.isRegistered<ClusterService>() &&
        !await Get.find<ClusterService>().confirmLiteRtRunsHere(filename)) {
      return;
    }
    final loadAction = await _confirmModelLoadSafety(
      filename: filename,
      path: path,
      fileBytes: fileBytes,
      isLiteRt: isLiteRt,
    );
    if (loadAction == _ModelLoadAction.cancel) return;
    if (loadAction == _ModelLoadAction.unloadAndContinue) {
      await unloadModel();
    }
    if (isLiteRt && !await _confirmLiteRtGpuWarning()) return;

    if (isImageModel(model ??
        AiModel(
          name: filename,
          filename: filename,
          url: '',
          size: '',
          description: '',
          template: '',
        ))) {
      // Auto-download TAESD for fast VAE decode if not present
      String? taesdPath;
      try {
        const taesdFilename = 'taesd.safetensors';
        const taesdUrl =
            'https://huggingface.co/madebyollin/taesd/resolve/main/diffusion_pytorch_model.safetensors';
        final hasTaesd = await _download.isModelDownloaded(taesdFilename);
        if (!hasTaesd &&
            !_download.activeDownloads.containsKey(taesdFilename)) {
          print('[ModelController] TAESD not found, downloading...');
          // On Android this only starts a background download and returns
          // immediately, so the file may not exist yet.
          await _download.downloadModel(url: taesdUrl, filename: taesdFilename);
        }
        // Only hand sd.cpp a TAESD path that is fully on disk; a missing
        // file makes the whole model load fail on every backend.
        if (await _download.isModelDownloaded(taesdFilename)) {
          taesdPath = await _download.modelPath(taesdFilename);
          print('[ModelController] Using TAESD for fast decode');
        } else {
          print('[ModelController] TAESD not ready yet, using standard VAE');
        }
      } catch (e) {
        print(
            '[ModelController] TAESD download failed (will use standard VAE): $e');
      }

      // Progress shows inline on the model's card, like text models.
      final result = await _localImage.loadModel(path,
          modelName: filename, taesdPath: taesdPath);

      final isError = !_localImage.isModelLoaded.value;
      showToast(
        isError ? '模型未加载' : '图像模型',
        result,
        tone: isError ? ToastTone.warning : ToastTone.success,
        duration:
            isError ? const Duration(seconds: 6) : const Duration(seconds: 2),
      );
    } else {
      // GGUF vision: pass the projector if it's on disk; otherwise fetch it
      // and load text-only for now.
      String? mmprojPath;
      var visionNote = '';
      if (model != null && model.hasVisionProjector && !isLiteRt) {
        if (await _download.isModelDownloaded(model.mmprojFilename)) {
          mmprojPath = await _download.modelPath(model.mmprojFilename);
        } else {
          visionNote = ' 视觉文件还在下载，重新加载模型后就能处理图片。';
          if (model.mmprojUrl.isNotEmpty &&
              !_download.activeDownloads.containsKey(model.mmprojFilename)) {
            unawaited(_downloadVisionFile(model));
          }
        }
      }
      final result = await _inference.loadModel(
        path,
        modelName: filename,
        modelRuntime: model?.runtime,
        enableLiteRtVision: model != null && isLiteRt && isVisionModel(model),
        mmprojPath: mmprojPath,
      );
      if (_inference.isModelLoaded.value) {
        final fallbackToText = result.toLowerCase().contains('text-only');
        _inference.isVisionLoaded.value = isLiteRt
            ? (!fallbackToText && model != null && isVisionModel(model))
            : _inference.ggufVisionLoaded;
        if (visionNote.isNotEmpty) {
          showToast('模型已加载', '$result$visionNote',
              tone: ToastTone.info, duration: const Duration(seconds: 5));
          await _settings.setInferenceMode('local');
          return;
        }
        await _settings.setInferenceMode('local');
        showToast('模型已加载', result, tone: ToastTone.success);
      } else {
        _showLoadFailedSheet(filename, result);
      }
    }
  }

  Future<int> _modelFileBytes(
    String filename,
    String path,
    AiModel? model,
  ) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.length();
        fileSizes[filename] = bytes;
        return bytes;
      }
    } catch (_) {}
    final cached = fileSizes[filename] ?? 0;
    if (cached > 0) return cached;
    return model == null ? 0 : _knownModelBytes(model);
  }

  Future<bool> _hasValidSafetensorsHeader(String path) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      final length = await file.length();
      if (length < 16) return false;
      raf = await file.open();
      final bytes = await raf.read(16);
      if (bytes.length < 16) return false;

      var headerLength = 0;
      for (var i = 0; i < 8; i++) {
        headerLength += bytes[i] << (8 * i);
      }

      if (headerLength <= 2 || headerLength > length - 8) return false;
      if (headerLength > 64 * 1024 * 1024) return false;
      return bytes[8] == 0x7B;
    } catch (_) {
      return false;
    } finally {
      await raf?.close();
    }
  }

  Future<bool> _hasLikelyValidLiteRtFile(String path, int fileBytes) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length < 10 * 1024 * 1024) return false;

      raf = await file.open();
      final bytes = await raf.read(16);
      if (bytes.length < 8) return false;

      // Verify LiteRT-LM magic identifier 'LITERTLM' at bytes 0-7
      final hasLmLiteRt = bytes[0] == 0x4C && // 'L'
          bytes[1] == 0x49 && // 'I'
          bytes[2] == 0x54 && // 'T'
          bytes[3] == 0x45 && // 'E'
          bytes[4] == 0x52 && // 'R'
          bytes[5] == 0x54 && // 'T'
          bytes[6] == 0x4C && // 'L'
          bytes[7] == 0x4D; // 'M'

      if (hasLmLiteRt) {
        return true;
      }

      // Note: We intentionally DO NOT allow standard TFLite models starting with 'TFL3' at offset 4
      // if they lack the 'LITERTLM' container header, because the native LiteRT-LM engine
      // strictly expects the .litertlm conversational bundle structure and will crash with a
      // SIGABRT native assert check failure if it is not present.
      return false;
    } catch (_) {
      return false;
    } finally {
      await raf?.close();
    }
  }

  Future<_ModelLoadAction> _confirmModelLoadSafety({
    required String filename,
    required String path,
    required int fileBytes,
    required bool isLiteRt,
  }) async {
    // Phone cluster: the model is split across phones, so this phone's free
    // memory alone says little. ClusterService checks the whole cluster's
    // memory (and offers this-phone-only when it fits) right before loading.
    if (!isLiteRt &&
        filename.toLowerCase().endsWith('.gguf') &&
        Get.isRegistered<ClusterService>() &&
        Get.find<ClusterService>().role == ClusterRole.master &&
        Get.find<ClusterService>().workers.isNotEmpty) {
      return _ModelLoadAction.continueLoad;
    }

    final availableRamGb = await _refreshAvailableRamGb();

    // Whatever is loaded now (text or image) gets unloaded first, so count
    // its memory as free when judging whether the new model fits.
    final loadedName = _inference.isModelLoaded.value
        ? _inference.loadedModelName.value
        : _localImage.isModelLoaded.value
            ? _localImage.loadedModelName.value
            : '';
    final hasLoadedModel = loadedName.isNotEmpty;
    final isSameModelLoaded = hasLoadedModel && loadedName == filename;
    final loadedBytes = hasLoadedModel ? (fileSizes[loadedName] ?? 0) : 0;

    final measuredBytes = (availableRamGb * 1024 * 1024 * 1024).round();
    final availableBytes =
        measuredBytes > 0 ? measuredBytes + loadedBytes : measuredBytes;
    final modelLabel = fileBytes > 0
        ? DownloadService.formatWholeMb(fileBytes)
        : '大小未知';
    final ramLabel = availableBytes > 0
        ? '${hasLoadedModel && loadedBytes > 0 ? '~' : ''}'
            '${DownloadService.formatWholeMb(availableBytes)}'
        : '未知';
    final lower = filename.toLowerCase();

    // For GGUF, estimate real usage from the file's header: weights plus the
    // KV cache for the configured context, which file size alone ignores.
    final gguf = lower.endsWith('.gguf') ? await readGgufInfo(path) : null;
    final contextTokens = _settings.contextSize.value;
    final estimatedBytes = gguf?.estimateBytes(contextTokens);
    final fits = estimatedBytes == null ||
        availableBytes <= 0 ||
        estimatedBytes <= availableBytes;
    final fittingContext = (gguf != null && !fits && availableBytes > 0)
        ? gguf.maxContextFitting(availableBytes)
        : null;

    final hasMeasuredMemory = availableBytes > 0 && fileBytes > 0;
    final isCriticallyLow = hasMeasuredMemory &&
        (estimatedBytes != null
            ? estimatedBytes > availableBytes
            : (availableBytes < fileBytes ||
                _isLowMemoryBytes(availableBytes)));
    final isLargeForRam =
        availableBytes > 0 && fileBytes > 0 && availableBytes < fileBytes * 2;
    final isLowRam = availableBytes > 0 && _isLowMemoryBytes(availableBytes);
    final String warning;
    if (gguf != null && !fits) {
      warning = fittingContext != null
          ? '按 $contextTokens tokens 的上下文，这个模型很可能放不进可用内存；'
              '把上下文设为 $fittingContext tokens 应该可以。'
          : '即使把上下文调小，这个模型对本机可用内存来说可能还是太大，'
              '试试更小的模型。';
    } else if (isCriticallyLow) {
      warning =
          '可用 RAM 低于推荐值。如果 Android 无法预留足够内存，应用可能闪退。';
    } else if (isLargeForRam || isLowRam || isLiteRt) {
      warning =
          '如果 Android 无法为模型预留足够内存，应用可能闪退。';
    } else {
      warning = '加载本地模型占用的内存可能比文件体积更大。';
    }
    final runtimeLabel = isLiteRt
        ? 'LiteRT-LM'
        : lower.endsWith('.gguf')
            ? 'GGUF'
            : lower.endsWith('.safetensors')
                ? '图像模型'
                : '本地模型';

    final warningSerious = (gguf != null && !fits) ||
        isCriticallyLow ||
        isLargeForRam ||
        isLowRam ||
        isLiteRt;

    final sheetContext = Get.context;
    if (sheetContext == null || !sheetContext.mounted) {
      return _ModelLoadAction.cancel;
    }
    final result = await showAppSheet<_ModelLoadAction>(
      sheetContext,
      title: isSameModelLoaded
          ? '重新加载模型？'
          : hasLoadedModel
              ? '切换模型？'
              : isCriticallyLow
                  ? '建议重启'
                  : '加载模型？',
      subtitle: filename,
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        void pop(_ModelLoadAction action) {
          if (ctx.mounted) Navigator.pop(ctx, action);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppGroup(children: [
              _detailRow(ctx, '运行时', runtimeLabel),
              _detailRow(
                  ctx,
                  hasLoadedModel ? '卸载后可用' : '可用 RAM',
                  ramLabel),
              _detailRow(ctx, '模型大小', modelLabel),
              if (gguf != null && estimatedBytes != null)
                _detailRow(
                  ctx,
                  '预计内存',
                  DownloadService.formatWholeMb(estimatedBytes),
                  note: '上下文 $contextTokens tokens 约需 '
                      '${DownloadService.formatWholeMb(gguf.kvCacheBytes(contextTokens))}',
                ),
            ]),
            if (hasLoadedModel) ...[
              const SizedBox(height: 12),
              AppNotice(
                isSameModelLoaded
                    ? '这个模型已经加载了，将先卸载再重新加载。'
                    : '已加载 $loadedName，将先卸载它。',
                icon: Icons.memory_rounded,
              ),
            ],
            const SizedBox(height: 12),
            AppNotice(
              warning,
              icon: warningSerious
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline_rounded,
              color: warningSerious ? t.orange : null,
            ),
            const SizedBox(height: 20),
            // A model is already loaded: the only choice is to swap it out.
            if (hasLoadedModel)
              Row(children: [
                Expanded(
                  child: TonalButton.neutral(
                    ctx,
                    label: '取消',
                    onTap: () => pop(_ModelLoadAction.cancel),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: '卸载并继续',
                    onPressed: () => pop(_ModelLoadAction.unloadAndContinue),
                  ),
                ),
              ])
            else ...[
              PrimaryButton(
                label: '继续',
                onPressed: () async {
                  await _refreshAvailableRamGb();
                  pop(_ModelLoadAction.continueLoad);
                },
              ),
              if (fittingContext != null) ...[
                const SizedBox(height: 10),
                TonalButton.neutral(
                  ctx,
                  label: '用 $fittingContext tokens 加载',
                  onTap: () async {
                    await _settings.setContextSize(fittingContext);
                    pop(_ModelLoadAction.continueLoad);
                  },
                ),
              ],
              if (isCriticallyLow) ...[
                const SizedBox(height: 10),
                TonalButton.neutral(
                  ctx,
                  label: '重启应用',
                  onTap: () async {
                    pop(_ModelLoadAction.cancel);
                    try {
                      await _androidImportChannel.invokeMethod('restartApp');
                    } catch (_) {
                      SystemNavigator.pop();
                    }
                  },
                ),
              ],
              const SizedBox(height: 10),
              TonalButton.neutral(
                ctx,
                label: '取消',
                onTap: () => pop(_ModelLoadAction.cancel),
              ),
            ],
          ],
        );
      },
    );
    return result ?? _ModelLoadAction.cancel;
  }

  Future<bool> _confirmLiteRtGpuWarning() async {
    final mode = _settings.liteRtPerformanceMode.value;
    if (mode == 'cpu_safe') return true;

    final accepted = _hive.getSetting<bool>(
          AppConstants.keyLiteRtGpuWarningAccepted,
          defaultValue: false,
        ) ??
        false;
    if (accepted) return true;

    final modeLabel = mode == 'gpu_fast' ? 'GPU 快速' : '自动快速';
    final context = Get.context;
    final confirmed = context == null
        ? false
        : await confirmSheet(
            context,
            title: '$modeLabel · LiteRT 提速',
            message:
                'GPU 能让 LiteRT 模型快很多，接近 Edge Gallery 的速度。'
                '部分手机上 GPU/OpenCL 可能在加载时导致应用闪退，'
                '遇到这种情况，下次加载时「自动快速」会改用 CPU。',
            confirmLabel: '继续',
          );

    if (confirmed == true) {
      await _hive.setSetting(AppConstants.keyLiteRtGpuWarningAccepted, true);
      return true;
    }
    return false;
  }

  bool _isLowMemoryBytes(int bytes) => bytes < 768 * 1024 * 1024;

  Future<double> _refreshAvailableRamGb() async {
    try {
      final device = Get.find<DeviceInfoService>();
      await device.refreshMemoryInfo();
      return device.availableRamGB.value;
    } catch (_) {
      return 0;
    }
  }

  Future<void> unloadModel() async {
    await _inference.unloadModel();
    await _localImage.unloadModel();
  }

  Future<void> importModelFromStorage() async {
    if (isImporting.value) {
      showToast('正在导入', '请等当前导入完成。',
          tone: ToastTone.warning);
      return;
    }

    if (Platform.isAndroid) {
      await _importModelWithAndroidPicker();
      return;
    }

    String? partialImportPath;
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.any,
        withData: false,
        withReadStream: true,
      );

      if (result != null) {
        final picked = result.files.single;
        final filename = picked.name;
        final lower = filename.toLowerCase();

        if (!lower.endsWith('.gguf') &&
            !lower.endsWith('.litertlm') &&
            !lower.endsWith('.safetensors')) {
          showToast('不支持的模型',
              '只能导入 .gguf、.litertlm 和 .safetensors 文件。',
              tone: ToastTone.warning);
          return;
        }

        final file = picked.path == null ? null : File(picked.path!);
        final totalBytes = picked.size > 0
            ? picked.size
            : file == null
                ? 0
                : await file.length();
        if (totalBytes <= 0) {
          showToast('导入失败', '所选文件是空的。',
              tone: ToastTone.error);
          return;
        }

        final sourceStream = picked.readStream ?? file?.openRead();
        if (sourceStream == null) {
          showToast(
            '导入失败',
            '无法读取所选文件，试试从本地存储重新选择。',
            tone: ToastTone.error,
          );
          return;
        }

        final modelsDir = await _download.modelsDir;
        final destPath = '$modelsDir/$filename';
        final partPath = '$destPath.part';
        partialImportPath = partPath;
        final destFile = File(destPath);
        final partFile = File(partPath);
        var shouldReplace = false;

        if (await destFile.exists()) {
          final replace = await _confirmReplace(filename);
          if (!replace) return;
          shouldReplace = true;
        }

        isImporting.value = true;
        importFileName.value = filename;
        importStatus.value = '正在复制到应用存储…';
        importCopiedBytes.value = 0;
        importTotalBytes.value = totalBytes;
        importBytesPerSecond.value = 0;

        if (await partFile.exists()) {
          await partFile.delete();
        }

        await _copyWithProgress(sourceStream, partFile);
        if (shouldReplace && await destFile.exists()) {
          await destFile.delete();
        }
        await partFile.rename(destPath);
        fileSizes[filename] = await File(destPath).length();

        await refreshDownloaded();
        modelScope.value = 'local';
        importStatus.value = '导入完成';
        showToast('导入成功', '模型 $filename 已导入。',
            tone: ToastTone.success);
      }
    } catch (e) {
      if (partialImportPath != null) {
        final partialFile = File(partialImportPath);
        if (await partialFile.exists()) {
          await partialFile.delete();
        }
      }
      Get.find<AppLogService>().error('Model import failed', details: e);
      showToast('导入失败', '$e', tone: ToastTone.error);
    } finally {
      isImporting.value = false;
      importFileName.value = '';
      importStatus.value = '';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;
    }
  }

  Future<void> _importModelWithAndroidPicker() async {
    try {
      isImporting.value = true;
      importFileName.value = '';
      importStatus.value = '请选择模型文件…';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;

      final result =
          await _androidImportChannel.invokeMapMethod<String, dynamic>(
        'pickAndImportModel',
        {'modelsDir': await _download.modelsDir},
      );

      if (result?['cancelled'] == true) return;

      final filename = result?['filename'] as String?;
      if (filename != null && filename.isNotEmpty) {
        fileSizes[filename] = (result?['bytes'] as num?)?.toInt() ??
            await _download.getModelSize(filename);
        await refreshDownloaded();
        modelScope.value = 'local';
        showToast('导入成功', '模型 $filename 已导入。',
            tone: ToastTone.success);
      }
    } on PlatformException catch (e) {
      Get.find<AppLogService>().error(
        'Android model import failed',
        details: '${e.code}: ${e.message}',
      );
      showToast('导入失败', e.message ?? e.code, tone: ToastTone.error);
    } catch (e) {
      Get.find<AppLogService>()
          .error('Android model import failed', details: e);
      showToast('导入失败', '$e', tone: ToastTone.error);
    } finally {
      isImporting.value = false;
      importFileName.value = '';
      importStatus.value = '';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;
    }
  }

  /// Folder import is Android only (storage access framework tree picker).
  bool get supportsFolderImport => Platform.isAndroid;

  /// Opens the system folder picker and lists the model files inside.
  /// Returns null when the user cancels.
  Future<List<FolderModelFile>?> pickModelFolder() async {
    try {
      final result = await _androidImportChannel
          .invokeMapMethod<String, dynamic>('pickModelFolder');
      if (result == null || result['cancelled'] == true) return null;
      return (result['files'] as List? ?? [])
          .map((f) => Map<String, dynamic>.from(f as Map))
          .map((f) => FolderModelFile(
                uri: f['uri'] as String,
                name: f['name'] as String,
                size: (f['size'] as num).toInt(),
              ))
          .toList();
    } on PlatformException catch (e) {
      Get.find<AppLogService>()
          .error('Folder scan failed', details: '${e.code}: ${e.message}');
      showToast('无法读取文件夹', e.message ?? e.code,
          tone: ToastTone.error);
      return null;
    }
  }

  /// Copies the chosen files into app storage one after another, with the
  /// same progress card as a single import.
  Future<void> importFolderFiles(List<FolderModelFile> files) async {
    if (files.isEmpty) return;
    if (isImporting.value) {
      showToast('正在导入', '请等当前导入完成。',
          tone: ToastTone.warning);
      return;
    }
    final modelsDir = await _download.modelsDir;
    var imported = 0;
    final failed = <String>[];
    isImporting.value = true;
    try {
      for (final file in files) {
        importFileName.value = file.name;
        importStatus.value = '正在复制到应用存储…';
        importCopiedBytes.value = 0;
        importTotalBytes.value = file.size;
        importBytesPerSecond.value = 0;
        try {
          final result =
              await _androidImportChannel.invokeMapMethod<String, dynamic>(
            'importModelUri',
            {'uri': file.uri, 'modelsDir': modelsDir},
          );
          final name = result?['filename'] as String? ?? file.name;
          fileSizes[name] = (result?['bytes'] as num?)?.toInt() ?? file.size;
          imported++;
        } on PlatformException catch (e) {
          failed.add(file.name);
          Get.find<AppLogService>().error('Folder import failed',
              details: '${file.name} · ${e.code}: ${e.message}');
        }
      }
      await refreshDownloaded();
      modelScope.value = 'local';
      if (failed.isEmpty) {
        showToast('导入成功',
            imported == 1 ? '已导入 1 个模型。' : '已导入 $imported 个模型。',
            tone: ToastTone.success);
      } else {
        showToast('部分导入失败',
            '已导入 $imported 个 · 无法导入 ${failed.join(', ')}',
            tone: ToastTone.warning);
      }
    } finally {
      isImporting.value = false;
      importFileName.value = '';
      importStatus.value = '';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;
    }
  }

  Future<void> _copyWithProgress(
    Stream<List<int>> source,
    File destination,
  ) async {
    final startedAt = DateTime.now();
    final sink = destination.openWrite();
    try {
      await for (final chunk in source) {
        sink.add(chunk);
        importCopiedBytes.value += chunk.length;
        final elapsed =
            DateTime.now().difference(startedAt).inMilliseconds / 1000;
        if (elapsed > 0) {
          importBytesPerSecond.value = importCopiedBytes.value / elapsed;
        }
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await destination.exists()) {
        await destination.delete();
      }
      rethrow;
    }
  }

  Future<bool> _confirmReplace(String filename) async {
    final context = Get.context;
    if (context == null) return false;
    return confirmSheet(
      context,
      title: '模型已存在',
      message:
          '本地应用存储中已导入名为「$filename」的模型文件，要替换它吗？',
      confirmLabel: '替换文件',
    );
  }

  /// Removes `.part` files left behind by imports or download finalisation
  /// that crashed. Several writers use `.part` concurrently (Android import,
  /// download finalise, desktop/iOS import), and this runs on every refresh,
  /// so only delete files that no active job owns and that haven't been
  /// written to recently; deleting a live one corrupts that download.
  Future<void> _deletePartialImports() async {
    const staleAfter = Duration(minutes: 10);
    try {
      final dir = Directory(await _download.modelsDir);
      if (!await dir.exists()) return;
      final busy = {
        ..._download.activeDownloads.keys,
        if (isImporting.value) importFileName.value,
      };
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final lower = name.toLowerCase();
        // A '.download' partial whose finished file already exists is a
        // leftover from an interrupted download that was later restarted.
        if (lower.endsWith('.download')) {
          final target = name.substring(0, name.length - '.download'.length);
          if (busy.contains(target)) continue;
          if (await File('${dir.path}/$target').exists()) await entity.delete();
          continue;
        }
        if (!lower.endsWith('.part')) continue;
        final target = name.substring(0, name.length - '.part'.length);
        if (busy.contains(target)) continue;
        final age = DateTime.now().difference(await entity.lastModified());
        if (age < staleAfter) continue;
        await entity.delete();
      }
    } catch (_) {}
  }

  /// Phone cluster errors (from ClusterService or the native cluster setup)
  /// already say what to do; anything else gets the generic tips.
  static bool _isClusterError(String rawError) {
    final lower = rawError.toLowerCase();
    return lower.contains('phone cluster') ||
        lower.contains('worker') ||
        lower.contains('cluster:') ||
        lower.contains('too big for these') ||
        lower.contains('塞不进');
  }

  String _getFriendlyErrorMessage(String rawError) {
    final lower = rawError.toLowerCase();
    if (_isClusterError(rawError)) {
      // "ERROR: Failed to load model — Exception: <message>"
      final at = rawError.lastIndexOf('Exception: ');
      return at >= 0 ? rawError.substring(at + 'Exception: '.length) : rawError;
    }
    if (lower.contains('unknown model architecture') ||
        lower.contains('unsupported model architecture')) {
      return '这个 GGUF 使用的模型架构不被内置的 llama.cpp 运行时支持。请更新应用运行时，或换一个用受支持架构导出的 GGUF。';
    }
    if (lower.contains('missing key') ||
        lower.contains('failed to load gguf split')) {
      return '这看起来是分片 GGUF 模型，但缺少一个或多个必需文件。加载前请把所有分片导入同一个文件夹。';
    }
    if (lower.contains('failed to load model from buffer') ||
        lower.contains('invalid_argument') ||
        lower.contains('invalid gguf') ||
        lower.contains('missing or unreadable') ||
        lower.contains('incomplete') ||
        lower.contains('corrupt')) {
      return '模型文件似乎不完整或已损坏，通常是下载中断或文件无效导致的。';
    }
    if (lower.contains('out of memory') ||
        lower.contains('allocate') ||
        lower.contains('oom') ||
        lower.contains('cannot allocate')) {
      return '加载这个模型时设备内存（RAM）不足。手机的内存限制比较严格，试试更小或量化更激进的模型（例如 1B 或 3B 参数、q4_k_m 量化）。';
    }
    if (lower.contains('opencl') ||
        lower.contains('vulkan') ||
        lower.contains('opengl') ||
        lower.contains('gpu') ||
        lower.contains('cl_') ||
        lower.contains('driver')) {
      return '初始化模型时出现硬件或 GPU 驱动错误。可以在设置里关闭 GPU 加速，或改用仅 CPU 推理。';
    }
    return '原生 AI 引擎在加载模型时遇到意外错误，请看下面的技术详情。';
  }

  void _showLoadFailedSheet(String filename, String result) {
    final friendlyMsg = _getFriendlyErrorMessage(result);
    final context = Get.context;
    if (context == null) {
      showToast('模型加载失败', friendlyMsg,
          tone: ToastTone.error, duration: const Duration(seconds: 6));
      return;
    }
    final showLiteRtTip = result.toLowerCase().contains('litert') ||
        filename.toLowerCase().endsWith('.litertlm');
    final isCluster = _isClusterError(result);
    bool showDetails = false;
    showAppSheet<void>(
      context,
      title: isCluster ? '手机集群加载失败' : '模型加载失败',
      subtitle: friendlyMsg,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final t = AppTokens.of(ctx);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader('排查建议',
                  padding: EdgeInsets.fromLTRB(0, 0, 0, 10)),
              if (isCluster) ...[
                _buildTipRow(ctx, Icons.hub_outlined,
                    '在每台工作节点上打开 PrivateLM > 手机集群，确认工作节点已开启并显示二维码。'),
                _buildTipRow(ctx, Icons.wifi_rounded,
                    '让所有设备连同一个 Wi-Fi。iPad 需要保持 PrivateLM 打开。'),
              ] else ...[
                _buildTipRow(ctx, Icons.delete_outline_rounded,
                    '删除该模型，然后完整地重新下载一次。'),
                _buildTipRow(ctx, Icons.memory_rounded,
                    '确保设备至少有 2-3 GB 可用 RAM。'),
              ],
              if (showLiteRtTip)
                _buildTipRow(ctx, Icons.tune_rounded,
                    '再确认一下这个 LiteRT-LM 文件是否与你的设备架构匹配。'),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: () => setState(() => showDetails = !showDetails),
                  borderRadius: BorderRadius.circular(8),
                  splashFactory: NoSplash.splashFactory,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          showDetails
                              ? '隐藏技术详情'
                              : '显示技术详情',
                          style: t.label.copyWith(color: t.text),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          showDetails
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: t.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: showDetails
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Container(
                          constraints: const BoxConstraints(maxHeight: 180),
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: t.fill,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              result,
                              style:
                                  t.mono.copyWith(fontSize: 11.5, height: 1.45),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 20),
              TonalButton.neutral(ctx,
                  label: '关闭', onTap: () => Navigator.pop(ctx)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTipRow(BuildContext context, IconData icon, String text) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: t.muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: t.caption.copyWith(color: t.text.withValues(alpha: 0.85)),
            ),
          ),
        ],
      ),
    );
  }

  /// Label / value line used in the load-model sheet.
  Widget _detailRow(BuildContext context, String label, String value,
      {String? note}) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.body.copyWith(fontSize: 14, color: t.muted)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value,
                    textAlign: TextAlign.end,
                    style: t.body
                        .copyWith(fontSize: 14, fontWeight: FontWeight.w500)),
                if (note != null) ...[
                  const SizedBox(height: 2),
                  Text(note, textAlign: TextAlign.end, style: t.small),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
