                        Button { openSamples() } label: {
                            Label("Browse Drum Samples", systemImage: "square.grid.2x2.fill")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .foregroundStyle(.white).background(akaiRed)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }