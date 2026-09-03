import Foundation

// パイプに流しても行単位で出力されるようにしておく。
setvbuf(stdout, nil, _IOLBF, 0)

SniffCommand.main()
