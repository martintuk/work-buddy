// Semantic keys shared by both exhaustive catalogs. Keep related keys together.
extension L10n {
    enum Key: CaseIterable, Sendable {
        // MARK: - Common
        case commonBack
        case commonRetry
        case commonClear
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
        case settingsMachineAccounts
        case settingsMachineAccountsPlaceholder
        case settingsMachineAccountsHelp
        case settingsOrganizations
        case settingsRefreshOrganizations
        case settingsSavedOrganization
        case settingsNoOrganizations

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
