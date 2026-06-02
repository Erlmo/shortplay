enum StepStatus { pending, running, success, error }

class WorkflowStep {
  const WorkflowStep({
    required this.id,
    required this.label,
    this.status = StepStatus.pending,
    this.detail,
  });

  final String id;
  final String label;
  final StepStatus status;
  final String? detail;

  WorkflowStep copyWith({StepStatus? status, String? detail}) {
    return WorkflowStep(
      id: id,
      label: label,
      status: status ?? this.status,
      detail: detail ?? this.detail,
    );
  }
}
