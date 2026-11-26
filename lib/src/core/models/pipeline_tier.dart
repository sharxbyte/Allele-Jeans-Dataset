/// Capture/processing tiers. Tiers are defined by what data the capture can
/// provide, because that (not raw compute) is what limits accuracy.
///
/// All tiers use the same setup: phone fixed on a tripod/stable surface, the
/// person turning in place on a floor mark. Scale comes from the user's
/// entered height unless a hardware depth sensor provides metric depth.
enum PipelineTier {
  /// Hardware depth (ToF / LiDAR) frames recorded alongside the turntable video.
  tier1DepthTurntable,

  /// RGB turntable video + front/side stills. Default for most phones,
  /// including the Galaxy A36.
  tier2RgbTurntable,

  /// Front + side stills only. Used when the device cannot record/process the
  /// turntable video, or the user cannot turn in place.
  tier3TwoView,
}

extension PipelineTierInfo on PipelineTier {
  String get precisionModeLabel {
    switch (this) {
      case PipelineTier.tier1DepthTurntable:
        return 'Precision Mode: High (Depth Sensor + 360° Scan)';
      case PipelineTier.tier2RgbTurntable:
        return 'Precision Mode: Standard (360° Scan)';
      case PipelineTier.tier3TwoView:
        return 'Precision Mode: Quick (Front + Side Photos)';
    }
  }

  /// Validation targets (95% limits of agreement vs. tape), in cm. These are
  /// goals to verify with real people, not guarantees.
  double get linearTargetCm {
    switch (this) {
      case PipelineTier.tier1DepthTurntable:
        return 0.5;
      case PipelineTier.tier2RgbTurntable:
        return 1.0;
      case PipelineTier.tier3TwoView:
        return 2.0;
    }
  }

  double get circumferenceTargetCm {
    switch (this) {
      case PipelineTier.tier1DepthTurntable:
        return 1.0;
      case PipelineTier.tier2RgbTurntable:
        return 1.5;
      case PipelineTier.tier3TwoView:
        // ANSUR II cross-validation: front breadth + side depth alone gives
        // ~±3-5 cm 95% LoA on waist/seat before any image error.
        return 3.5;
    }
  }

  bool get usesTurntableVideo => this != PipelineTier.tier3TwoView;
}
