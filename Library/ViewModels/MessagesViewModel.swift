import Foundation
import KsApi
import Prelude
import ReactiveSwift

public protocol MessagesViewModelInputs {
  /// Call when the backing button is pressed.
  func backingInfoPressed()

  /// Call when block user is tapped
  func blockUser()

  /// Configures the view model with either a message thread or a project and a backing.
  func configureWith(data: Either<MessageThread, (project: Project, backing: Backing)>)

  /// Call when the message dialog has told us that a message was successfully posted.
  func messageSent(_ message: Message)

  /// Call when the project banner is tapped.
  func projectBannerTapped()

  /// Call when the reply button is pressed.
  func replyButtonPressed()

  /// Call when the view loads.
  func viewDidLoad()
}

public protocol MessagesViewModelOutputs {
  /**
   Emits a Backing and Project that can be used to populate the BackingCell.
   The boolean tells if navigation to this screen occurred from the backing info screen.
   */
  var backingAndProjectAndIsFromBacking: Signal<(Backing, Project, Bool), Never> { get }

  /// Emits a boolean that determines if the empty state is visible and a message to display.
  var emptyStateIsVisibleAndMessageToUser: Signal<(Bool, String), Never> { get }

  /// Emits when we should go to the backing screen.
  var goToBacking: Signal<ManagePledgeViewParamConfigData, Never> { get }

  /// Emits when we should go to the projet.
  var goToProject: Signal<(Project, RefTag), Never> { get }

  /// Emits a list of messages to be displayed.
  var messages: Signal<[Message], Never> { get }

  /// Emits when we should show the message dialog.
  var presentMessageDialog: Signal<(MessageThread, KSRAnalytics.MessageDialogContext), Never> { get }

  /// Emits the project we are viewing the messages for.
  var project: Signal<Project, Never> { get }

  /// Emits a bool whether the reply button is enabled.
  var replyButtonIsEnabled: Signal<Bool, Never> { get }

  /// Emits when the thread has been marked as read.
  var successfullyMarkedAsRead: Signal<(), Never> { get }

  /// Emits when a request to block a user has been made
  var userBlocked: Signal<Bool, Never> { get }
}

public protocol MessagesViewModelType {
  var inputs: MessagesViewModelInputs { get }
  var outputs: MessagesViewModelOutputs { get }
}

public final class MessagesViewModel: MessagesViewModelType, MessagesViewModelInputs,
  MessagesViewModelOutputs {
  public init() {
    let configData = self.configData.signal.skipNil()
      .takeWhen(self.viewDidLoadProperty.signal)

    let configBacking = configData.map { $0.right?.backing }

    let configThread = configData.map { $0.left }
      .skipNil()

    let currentUser = self.viewDidLoadProperty.signal
      .map { AppEnvironment.current.currentUser }
      .skipNil()

    self.project = configData
      .map {
        switch $0 {
        case let .left(thread):
          return thread.project
        case let .right((project, _)):
          return project
        }
      }

    let backingOrThread = Signal.merge(
      configBacking.skipNil().map(Either.left),
      configThread.map(Either.right)
    )

    let messageThreadEnvelopeEvent = Signal.merge(
      backingOrThread,
      backingOrThread.takeWhen(self.messageSentProperty.signal)
    )
    .switchMap { backingOrThread
      -> SignalProducer<Signal<MessageThreadEnvelope?, ErrorEnvelope>.Event, Never> in
      switch backingOrThread {
      case let .left(backing):
        return AppEnvironment.current.apiService.fetchMessageThread(backing: backing)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .materialize()
      case let .right(thread):
        return AppEnvironment.current.apiService.fetchMessageThread(messageThreadId: thread.id)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .map(MessageThreadEnvelope?.some)
          .materialize()
      }
    }

    let messageThreadEnvelope = messageThreadEnvelopeEvent.values().skipNil()

    let participant = messageThreadEnvelope.map { $0.messageThread.participant }

    self.backingAndProjectAndIsFromBacking = Signal.combineLatest(
      configBacking, self.project, participant, currentUser
    )
    .switchMap { value -> SignalProducer<(Backing, Project, Bool), Never> in
      let (backing, project, participant, currentUser) = value

      if let backing = backing {
        return SignalProducer(value: (backing, project, true))
      }

      let request = project.personalization.isBacking == .some(true)
        ? AppEnvironment.current.apiService.fetchBacking(forProject: project, forUser: currentUser)
        : AppEnvironment.current.apiService.fetchBacking(forProject: project, forUser: participant)

      return request
        .map { ($0, project, false) }
        .demoteErrors()
    }

    self.messages = messageThreadEnvelope
      .map { $0.messages }
      .sort { $0.id > $1.id }

    self.emptyStateIsVisibleAndMessageToUser = Signal.merge(
      self.viewDidLoadProperty.signal.mapConst((false, "")),
      Signal.combineLatest(
        messageThreadEnvelopeEvent.values().filter(isNil),
        configBacking.skipNil(),
        self.project
      )
      .map { _, backing, project in
        let isCreatorOrCollaborator = !project.memberData.permissions.isEmpty
          && backing.backer != AppEnvironment.current.currentUser
        let message = isCreatorOrCollaborator
          ? Strings.messages_empty_state_message_creator()
          : Strings.messages_empty_state_message_backer()
        return (true, message)
      }
    )

    self.replyButtonIsEnabled = Signal.merge(
      self.viewDidLoadProperty.signal.mapConst(false),
      self.messages.map { !$0.isEmpty }
    )

    self.presentMessageDialog = messageThreadEnvelope
      .map { ($0.messageThread, .messages) }
      .takeWhen(self.replyButtonPressedProperty.signal)

    self.goToBacking = Signal.combineLatest(messageThreadEnvelope, currentUser)
      .takeWhen(self.backingInfoPressedProperty.signal)
      .compactMap { env, _ -> ManagePledgeViewParamConfigData? in
        guard let backing = env.messageThread.backing else {
          return nil
        }

        let project = env.messageThread.project

        return (projectParam: Param.slug(project.slug), backingParam: Param.id(backing.id))
      }

    self.goToProject = self.project.takeWhen(self.projectBannerTappedProperty.signal)
      .map { ($0, .messageThread) }

    self.successfullyMarkedAsRead = messageThreadEnvelope
      .switchMap {
        AppEnvironment.current.apiService.markAsRead(messageThread: $0.messageThread)
          .demoteErrors()
      }
      .ignoreValues()

    // TODO: Call blocking GraphQL mutation
    self.userBlocked = self.blockUserProperty.signal.map { true }

    self.userBlocked.observeValues { didBlock in
      guard didBlock == true else { return }
      NotificationCenter.default.post(.init(name: .ksr_blockedUser))
    }
  }

  private let backingInfoPressedProperty = MutableProperty(())
  public func backingInfoPressed() {
    self.backingInfoPressedProperty.value = ()
  }

  private let blockUserProperty = MutableProperty(())
  public func blockUser() {
    self.blockUserProperty.value = ()
  }

  private let configData = MutableProperty<Either<MessageThread, (project: Project, backing: Backing)>?>(nil)
  public func configureWith(data: Either<MessageThread, (project: Project, backing: Backing)>) {
    self.configData.value = data
  }

  private let messageSentProperty = MutableProperty<Message?>(nil)
  public func messageSent(_ message: Message) {
    self.messageSentProperty.value = message
  }

  private let projectBannerTappedProperty = MutableProperty(())
  public func projectBannerTapped() {
    self.projectBannerTappedProperty.value = ()
  }

  private let replyButtonPressedProperty = MutableProperty(())
  public func replyButtonPressed() {
    self.replyButtonPressedProperty.value = ()
  }

  private let viewDidLoadProperty = MutableProperty(())
  public func viewDidLoad() {
    self.viewDidLoadProperty.value = ()
  }

  public let backingAndProjectAndIsFromBacking: Signal<(Backing, Project, Bool), Never>
  public let emptyStateIsVisibleAndMessageToUser: Signal<(Bool, String), Never>
  public let goToBacking: Signal<ManagePledgeViewParamConfigData, Never>
  public let goToProject: Signal<(Project, RefTag), Never>
  public let messages: Signal<[Message], Never>
  public let presentMessageDialog: Signal<(MessageThread, KSRAnalytics.MessageDialogContext), Never>
  public let project: Signal<Project, Never>
  public let replyButtonIsEnabled: Signal<Bool, Never>
  public let successfullyMarkedAsRead: Signal<(), Never>
  public let userBlocked: Signal<Bool, Never>

  public var inputs: MessagesViewModelInputs { return self }
  public var outputs: MessagesViewModelOutputs { return self }
}
