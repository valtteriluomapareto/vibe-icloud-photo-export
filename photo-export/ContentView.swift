//
//  ContentView.swift
//  photo-export
//
//  Created by Valtteri Luoma on 22.4.2025.
//

import SwiftUI
import Photos
import AppKit

struct ContentView: View {
    @StateObject private var photoLibraryManager = PhotoLibraryManager()
    @State private var isShowingAuthorizationView = false
    
    var body: some View {
        NavigationView {
            ZStack {
                if photoLibraryManager.isAuthorized {
                    MainView()
                        .environmentObject(photoLibraryManager)
                } else {
                    AuthorizationView(photoLibraryManager: photoLibraryManager)
                }
            }
            .navigationTitle("Photo Export")
        }
        .onAppear {
            isShowingAuthorizationView = photoLibraryManager.authorizationStatus != .authorized
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

struct AuthorizationView: View {
    @ObservedObject var photoLibraryManager: PhotoLibraryManager
    @State private var isRequestingAuthorization = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .foregroundColor(.blue)
            
            Text("Photo Library Access Required")
                .font(.title)
                .bold()
            
            Text("This app needs access to your Photos library to back up photos and videos to external storage.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: {
                requestPermission()
            }) {
                Text("Grant Access")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            .disabled(isRequestingAuthorization)
            
            if isRequestingAuthorization {
                ProgressView()
                    .padding()
            }
            
            if photoLibraryManager.authorizationStatus == .denied || photoLibraryManager.authorizationStatus == .restricted {
                Text("Please enable Photos access in Settings to use this app.")
                    .foregroundColor(.red)
                    .padding()
                
                Button("Open System Preferences") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                }
                .padding()
            }
        }
        .padding()
    }
    
    private func requestPermission() {
        isRequestingAuthorization = true
        
        Task {
            _ = await photoLibraryManager.requestAuthorization()
            isRequestingAuthorization = false
        }
    }
}

struct MainView: View {
    @EnvironmentObject var photoLibraryManager: PhotoLibraryManager
    
    var body: some View {
        TestPhotoAccessView()
            .environmentObject(photoLibraryManager)
    }
}

#Preview {
    ContentView()
}
