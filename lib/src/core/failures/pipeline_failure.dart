/// Typed failures for the photogrammetry pipeline. Every async or native call
/// that can fail surfaces one of these, with a log-oriented [message] and a
/// plain-language [userMessage] safe to show on screen.
sealed class PipelineFailure implements Exception {
  final String code;
  final String message;
  final String userMessage;
  final Object? cause;

  const PipelineFailure(this.code, this.message, this.userMessage, [this.cause]);

  @override
  String toString() => '$runtimeType($code): $message${cause == null ? '' : ' <- $cause'}';
}

class CaptureFailure extends PipelineFailure {
  const CaptureFailure(super.code, super.message, super.userMessage, [super.cause]);
}

class SegmentationFailure extends PipelineFailure {
  const SegmentationFailure(super.code, super.message, super.userMessage, [super.cause]);
}

class PoseDetectionFailure extends PipelineFailure {
  const PoseDetectionFailure(super.code, super.message, super.userMessage, [super.cause]);
}

class BodyFitFailure extends PipelineFailure {
  const BodyFitFailure(super.code, super.message, super.userMessage, [super.cause]);
}

class MeasurementFailure extends PipelineFailure {
  const MeasurementFailure(super.code, super.message, super.userMessage, [super.cause]);
}

class JobFailure extends PipelineFailure {
  const JobFailure(super.code, super.message, super.userMessage, [super.cause]);
}

class ExportFailure extends PipelineFailure {
  const ExportFailure(super.code, super.message, super.userMessage, [super.cause]);
}

/// A native library or model asset the pipeline needs is not present.
class MissingDependencyFailure extends PipelineFailure {
  const MissingDependencyFailure(super.code, super.message, super.userMessage, [super.cause]);
}
