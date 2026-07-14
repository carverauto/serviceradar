/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::marker::PhantomData;

// ============================================================================
// Parametric Monad: Type-Safe State Machine
// ============================================================================

// ENGINEERING VALUE:
// Standard Monads (State<S, A>) assume the state type 'S' never changes.
// But in many systems (e.g., Protocols, Builders), the state TYPE changes.
// Uninitialized -> Authenticated -> Connected.
//
// Parametric Monad (Indexed Monad) allows the state type to evolve:
// bind: M<S1, S2, A> -> (A -> M<S2, S3, B>) -> M<S1, S3, B>
//
// This enforces the correct sequence of operations at COMPILE TIME.
// You cannot "Send Data" before "Connect".
fn main() {
    println!("=== DeepCausality HKT: Parametric Monad Pattern ===\n");

    println!("--- Protocol State Machine ---");

    // Step 1: Connect (Disconnected -> Connected)
    let connect = || -> Transition<Disconnected, Connected, String> {
        println!("Action: Connecting...");
        Transition::new("Connection_ID_123".to_string())
    };

    // Step 2: Authenticate (Connected -> Authenticated)
    let authenticate = |conn_id: String| -> Transition<Connected, Authenticated, String> {
        println!("Action: Authenticating {}...", conn_id);
        Transition::new("User_Session_99".to_string())
    };

    // Step 3: Send Data (Authenticated -> Authenticated)
    let send_data = |session: String| -> Transition<Authenticated, Authenticated, usize> {
        println!("Action: Sending data via {}...", session);
        Transition::new(1024) // Bytes sent
    };

    // EXECUTION
    // We chain them: Disconnected -> Connected -> Authenticated -> Authenticated
    // The types align perfectly:
    // S1=Disc, S2=Conn
    //          S2=Conn, S3=Auth
    //                   S3=Auth, S4=Auth

    let t1 = connect();
    let t2 = ibind(t1, authenticate);
    let t3 = ibind(t2, send_data);

    println!("Final Result: {} bytes sent", t3.val);

    // COMPILE-TIME SAFETY:
    // If we tried to call 'send_data' immediately after 'connect',
    // the types would mismatch:
    // connect returns Post=Connected
    // send_data expects Pre=Authenticated
    // compile error!
}

// States
#[derive(Debug)]
struct Disconnected;
#[derive(Debug)]
struct Connected;
#[derive(Debug)]
struct Authenticated;

// The Parametric Monad: Transition<Pre, Post, Val>
// Represents a computation starting in 'Pre' state, ending in 'Post' state, yielding 'Val'.
struct Transition<Pre, Post, Val> {
    val: Val,
    _phantom: PhantomData<(Pre, Post)>,
}

impl<Pre, Post, Val> Transition<Pre, Post, Val> {
    fn new(val: Val) -> Self {
        Self {
            val,
            _phantom: PhantomData,
        }
    }
}

// Helper to simulate Parametric Bind
// (Real trait would be ParametricMonad::ibind)
fn ibind<S1, S2, S3, A, B, F>(m: Transition<S1, S2, A>, f: F) -> Transition<S1, S3, B>
where
    F: Fn(A) -> Transition<S2, S3, B>,
{
    let next = f(m.val);
    Transition::new(next.val)
}
