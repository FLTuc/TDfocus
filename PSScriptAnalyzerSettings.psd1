@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                        # messages d'installation et de test destinés à l'utilisateur
        'PSUseShouldProcessForStateChangingFunctions',  # fonctions internes, pas de cmdlets publiques
        'PSUseSingularNouns',
        'PSReviewUnusedParameter',                      # signatures imposées des gestionnaires d'événements WPF
        'PSAvoidUsingConvertToSecureStringWithPlainText' # jeton chiffré aussitôt avec DPAPI (Protect-TdSecret)
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
