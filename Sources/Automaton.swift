//
//  Automaton.swift
//  ReactiveAutomaton
//
//  Created by Yasuhiro Inami on 2016-05-07.
//  Copyright © 2016 Yasuhiro Inami. All rights reserved.
//

import Result
import ReactiveSwift

/// Deterministic finite state machine that receives "input"
/// and with "current state" transform to "next state" & "output (additional effect)".
public final class Automaton<State, Input>
{
    /// Basic state-transition function type.
    public typealias Mapping = (State, Input) -> State?

    /// Transducer (input & output) mapping with
    /// `SignalProducer<Input, NoError>` (additional effect) as output,
    /// which may emit next input values for continuous state-transitions.
    public typealias EffectMapping = (State, Input) -> (State, SignalProducer<Input, NoError>)?

    /// `Reply` signal that notifies either `.success` or `.failure` of state-transition on every input.
    public let replies: Signal<Reply<State, Input>, NoError>

    /// Current state.
    public let state: Property<State>

    fileprivate let _replyObserver: Observer<Reply<State, Input>, NoError>

    fileprivate var _disposable: Disposable?

    ///
    /// Initializer using `Mapping`.
    ///
    /// - Parameters:
    ///   - state: Initial state.
    ///   - input: `Signal<Input, NoError>` that automaton receives.
    ///   - mapping: Simple `Mapping` that designates next state only (no additional effect).
    ///
    public convenience init(state initialState: State, input inputSignal: Signal<Input, NoError>, mapping: @escaping Mapping)
    {
        self.init(state: initialState, input: inputSignal, mapping: _compose(_toEffectMapping, mapping))
    }

    ///
    /// Initializer using `EffectMapping`.
    ///
    /// - Parameters:
    ///   - state: Initial state.
    ///   - input: `Signal<Input, NoError>` that automaton receives.
    ///   - mapping: `EffectMapping` that designates next state and also generates additional effect.
    ///   - strategy: `FlattenStrategy` that flattens additional effect generated by `EffectMapping`.
    ///
    public init(state initialState: State, input inputSignal: Signal<Input, NoError>, mapping: @escaping EffectMapping, strategy: FlattenStrategy = .merge)
    {
        let stateProperty = MutableProperty(initialState)
        self.state = Property(stateProperty)

        (self.replies, self._replyObserver) = Signal<Reply<State, Input>, NoError>.pipe()

        /// Recursive input-producer that sends inputs from `inputSignal`
        /// and also from additional effect generated by `EffectMapping`.
        func recurInputProducer(_ inputProducer: SignalProducer<Input, NoError>, strategy: FlattenStrategy) -> SignalProducer<Input, NoError>
        {
            return SignalProducer<Input, NoError> { observer, disposable in
                inputProducer
                    .withLatest(from: stateProperty.producer)
                    .map { input, fromState in
                        return (input, fromState, mapping(fromState, input)?.1)
                    }
                    .startWithSignal { mappingSignal, mappingSignalDisposable in
                        //
                        // NOTE:
                        // `mergedProducer` (below) doesn't emit `.Interrupted` although `mappingSignal` sends it,
                        // so propagate it to returning producer manually.
                        //
                        disposable += mappingSignal.observeInterrupted {
                            observer.sendInterrupted()
                        }

                        //
                        // NOTE:
                        // Split `mappingSignal` into `successSignal` and `failureSignal` (and merge later) so that
                        // inner producers of `flatMap(strategy)` in `successSignal` don't get interrupted by mapping failure.
                        //
                        let successSignal = mappingSignal
                            .filterMap { input, fromState, effect in
                                return effect.map { (input, fromState, $0) }
                            }
                            .flatMap(strategy) { input, _, effect -> SignalProducer<Input, NoError> in
                                return recurInputProducer(effect, strategy: strategy)
                                    .prefix(value: input)
                            }

                        let failureSignal = mappingSignal
                            .filterMap { input, _, effect -> Input? in
                                return effect == nil ? input : nil
                            }

                        let mergedProducer = SignalProducer(values: failureSignal, successSignal).flatten(.merge)

                        disposable += mergedProducer.start(observer)
                        disposable += mappingSignalDisposable
                    }
            }
        }

        recurInputProducer(SignalProducer(inputSignal), strategy: strategy)
            .withLatest(from: stateProperty.producer)
            .flatMap(.merge) { input, fromState -> SignalProducer<Reply<State, Input>, NoError> in
                if let (toState, _) = mapping(fromState, input) {
                    return .init(value: .success(input, fromState, toState))
                }
                else {
                    return .init(value: .failure(input, fromState))
                }
            }
            .startWithSignal { replySignal, disposable in
                self._disposable = disposable

                stateProperty <~ replySignal
                    .flatMap(.merge) { reply -> SignalProducer<State, NoError> in
                        if let toState = reply.toState {
                            return .init(value: toState)
                        }
                        else {
                            return .empty
                        }
                    }

                replySignal.observe(self._replyObserver)
            }
    }

    deinit
    {
        self._replyObserver.sendCompleted()
        self._disposable?.dispose()
    }

}

// MARK: Private

private func _compose<A, B, C>(_ g: @escaping (B) -> C, _ f: @escaping (A) -> B) -> (A) -> C
{
    return { x in g(f(x)) }
}

private func _toEffectMapping<State, Input>(_ toState: State?) -> (State, SignalProducer<Input, NoError>)?
{
    if let toState = toState {
        return (toState, .empty)
    }
    else {
        return nil
    }
}
