//
//  GossipHarness.swift
//
//  Run with: droppykit run
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//

import DroppyKit
import DroppyKitHarness
import Gossip

@main
struct GossipHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { GossipDroplet.sample() }
}
