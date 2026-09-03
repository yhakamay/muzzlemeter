import Foundation

// Line-buffer stdout so output still appears line by line when piped.
setvbuf(stdout, nil, _IOLBF, 0)

SniffCommand.main()
