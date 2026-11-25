@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Test helpers and demo scripts create temp folders/files on purpose; ShouldProcess there adds noise.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
