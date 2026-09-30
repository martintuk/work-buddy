// Semantic keys shared by both exhaustive catalogs. Keep related keys together.
extension L10n {
    enum Key: CaseIterable, Sendable {
        // MARK: - Common
        case commonBack
        case commonRetry
        case commonClear
        case commonCopyLink
        case commonCancel
        case commonConfirm
        case commonNothingPending
        case commonEnabled
        case commonDisabled
        case commonRefreshing

        // MARK: - Settings
        case settingsTitle
        case settingsClose
        case settingsLanguage
        case settingsEmptySections
        case settingsEmptySectionsHelp
        case settingsAutoConfirmActions
        case settingsAutoConfirmActionsHelp
        case settingsMachineAccounts
        case settingsMachineAccountsPlaceholder
        case settingsMachineAccountsHelp
        case settingsOrganizations
        case settingsRefreshOrganizations
        case settingsSavedOrganization
        case settingsNoOrganizations
        case settingsTeamDependabot
        case settingsTeamDependabotHelp
        case settingsRefreshTeams
        case settingsNoTeams
        case errorTeam
        case errorTeamDiscovery

        // MARK: - Editor
        case settingsEditor
        case editorChoose
        case editorSelectInSettings
        case editorAssociateFolderInRepositories
        case editorSelect
        case editorOther
        case editorOpen
        case editorOpenIn
        case editorInvalidApplication
        case editorMissingApplication
        case editorMissingFolder
        case editorBranchUnavailable
        case editorOpenProject
        case editorBranchLocalChanges
        case editorBranchOperationInProgress
        case editorBranchWrongRepository

        // MARK: - Agent CLI
        case agentTerminal
        case agentCustomTerminal
        case agentTerminalCommand
        case agentTerminalCommandHelp
        case agentTerminalCommandMissing
        case agentTitle
        case agentChoose
        case agentSelectInSettings
        case agentCustom
        case agentCommand
        case agentOpen
        case agentOpenWith
        case agentOpenCustom
        case agentMissingTerminal
        case agentGhosttyVersion
        case agentAutomationDenied
        case agentLaunchFailed

        // MARK: - Notifications
        case notificationsTitle
        case notificationsTest
        case notificationsTestHelp
        case notificationsEnable
        case notificationsToggleHelp
        case notificationsEnableAccessibility
        case notificationsTestBody
        case notificationsUnavailable
        case notificationsDenied
        case notificationsNewReview
        case notificationsNewMerge

        // MARK: - Repositories
        case repositoriesTitle
        case repositoriesSearchPlaceholder
        case repositoriesSearch
        case repositoriesEmpty
        case repositoriesNotLoaded
        case repositoriesNoMatches
        case repositoriesUnfavorite
        case repositoriesFavorite
        case repositoriesDeselect
        case repositoriesSolo
        case repositoriesUnmute
        case repositoriesMute
        case repositoriesFilterActive
        case repositoriesAll
        case repositoriesFilterHelp
        case repositoriesFilteredEmpty
        case repositoriesHiddenResults
        case repositoriesShowAll
        case repositoriesFavoriteAccessibility
        case repositoriesSelectAccessibility
        case repositoriesMuteAccessibility
        case repositoriesAssociateFolder
        case repositoriesChooseFolder
        case repositoriesRemoveFolder
        case repositoriesNoFolder
        case repositoriesInvalidFolder

        // MARK: - Panel
        case panelCategory
        case panelRefresh
        case panelPin
        case panelUnpin

        // MARK: - Menu
        case menuAbout
        case menuExportDiagnostics
        case menuQuit

        // MARK: - Jira
        case jiraLoading
        case jiraMissingCLI
        case jiraInstallCLI
        case jiraLoadFailed
        case jiraAwaitingSHR
        case jiraRecentlyCreated
        case jiraTickets
        case jiraConnect
        case jiraCommandCopied
        case jiraCopyCommand
        case jiraCheckAgain
        case jiraOpen

        // MARK: - Github
        case githubReplyHelp
        case githubWaitingHelp
        case githubDependabotWarning
        case githubUnknownMergeMethod
        case githubLoadFailed
        case githubLoading
        case githubNoReviews
        case githubMerge
        case githubFix
        case githubReply
        case githubWaiting
        case githubAutomation
        case githubAutomationNotReady
        case batchTitle
        case batchOpen
        case batchViewResults
        case batchSelectAll
        case batchDeselectAll
        case batchApproveCount
        case batchSelectionCount
        case batchSelected
        case batchNotSelected
        case batchProgress
        case batchEmpty
        case batchPending
        case batchChecking
        case batchApproving
        case batchApproved
        case batchApprovedCount
        case batchSkippedCount
        case batchFailedCount
        case batchChanged
        case batchNotReady
        case batchAlreadyApproved
        case batchClosed
        case batchScopeChanged
        case batchAccountChanged
        case batchStopped
        case batchStop
        case batchStopping
        case batchStopHelp
        case batchDone
        case batchNew
        case automationFilterAll
        case automationFilterHide
        case automationFilterOnly
        case automationFilterHelp
        case prApprovalCount
        case prApprovalsSatisfied
        case prApprovalsRequired
        case prChangesRequested
        case prApprovalStatusUnknown
        case githubAutomationHelp
        case githubIgnored
        case githubReview
        case githubApproved
        case githubApprovedHelp
        case githubPullRequests

        // MARK: - Section
        case sectionExpanded
        case sectionCollapsed
        case sectionHide
        case sectionShow
        case sectionHideTitle
        case sectionShowTitle

        // MARK: - Pr
        case prDraft
        case prCI
        case prActions
        case prOpen
        case prIgnore
        case prRestore
        case prApprove
        case prRebase
        case prDependabotRebase
        case prMerge
        case prApproved
        case prRebased
        case prDependabotRequested
        case prMerged
        case prBehindOne
        case prBehindMany

        // MARK: - Merge
        case mergeSquash
        case mergeCommit
        case mergeRebase

        // MARK: - Error
        case errorGHMissing
        case errorACLIMissing
        case errorACLIAuthentication
        case errorConversationCursor
        case errorNoAttempts
        case errorDependabotRebase
        case errorMergeMethod
        case errorOrganization
        case errorMachineAccount
        case errorGHAuthentication
        case errorGHCommand
        case errorGHResponse
        case errorACLICommand
        case errorACLIResponse
        case errorMissingThreads
        case errorMissingComments

        // MARK: - Summary
        case summaryReview
        case summaryMerge
        case summaryFix
        case summaryReply

        // MARK: - Confirm
        case confirmDependabot
        case confirmAction

        // MARK: - Updated
        case updatedSecondsOne
        case updatedSecondsMany
        case updatedMinutesOne
        case updatedMinutesMany
        case updatedHoursOne
        case updatedHoursMany
        case updatedDaysOne
        case updatedDaysMany
    }
}
