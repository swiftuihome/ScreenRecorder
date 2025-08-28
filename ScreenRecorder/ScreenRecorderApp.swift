//
//  ScreenRecorderApp.swift
//  ScreenRecorder
//
//  Created by devlink on 2025/8/28.
//

import SwiftUI

@main
struct ScreenRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 300, height: 200)
        }
        .windowResizability(.contentSize)
    }
}
