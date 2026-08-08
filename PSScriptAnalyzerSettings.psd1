@{
    Severity = @(
        'Warning',
        'Error'
    )
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidOverwritingBuiltInCmdlets',
        'PSReviewUnusedParameter',
        'PSUseCmdletCorrectly'
    )
}