import SwiftUI
import WidgetKit

// AI CONTEXT — Widgets/AutohopWidgetsBundle.swift
//
// Widget extension entry point. Stage 1 registers one adaptive configuration
// for the three Home Screen families and two Lock Screen families. Do not add
// app services, database bootstrapping, networking, or mutable playback state
// here. Additional discovery/stats widgets require the separate product
// decision reserved by WIDGETS_IMPLEMENTATION_PROPOSAL.md Stage 5.

@main
struct AutohopWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingUpNextWidget()
    }
}
