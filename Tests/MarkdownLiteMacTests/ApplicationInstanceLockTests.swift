import Foundation
import Testing

@testable import MarkdownLiteMac

// 覆盖同路径互斥、路径隔离、生命周期释放和锁文件安全属性。
@Suite("应用单实例锁")
struct ApplicationInstanceLockTests {
    // 同一固定路径的第二个持有者必须立即得到已运行错误。
    @Test("相同路径非阻塞互斥")
    func samePathIsMutuallyExclusive() throws {
        // 每个测试使用唯一目录，避免与真实应用及并行测试竞争。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后只删除本次创建的隔离目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 两个实例明确竞争同一个固定文件。
        let lockFileURL = rootDirectory.appendingPathComponent("same.lock", isDirectory: false)
        // 第一个实例成功持有独占锁。
        let firstLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)

        // 保持首锁存活期间尝试第二次非阻塞获取。
        withExtendedLifetime(firstLock) {
            do {
                // 若错误地获取成功，测试必须显式失败。
                let secondLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
                // 防止优化器在失败记录前提前释放意外取得的锁。
                withExtendedLifetime(secondLock) {}
                // 相同路径同时成功会破坏恢复数据单写者约束。
                Issue.record("相同路径被两个实例同时获取")
            } catch ApplicationInstanceLockError.alreadyRunning {
                // 明确的已运行分类就是预期结果。
            } catch {
                // 锁竞争不能被误报为普通 IO 故障。
                Issue.record("相同路径返回了错误类型：\(error)")
            }
        }
    }

    // 不同恢复根目录应拥有独立锁，保证测试和显式隔离环境互不影响。
    @Test("不同路径可以独立持有")
    func differentPathsAreIndependent() throws {
        // 唯一根目录集中容纳两个不会竞争的锁文件。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后清理唯一隔离目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 两个不同文件代表两个独立恢复数据目录。
        let firstURL = rootDirectory.appendingPathComponent("first.lock", isDirectory: false)
        // 第二路径不能被第一路径的 flock 影响。
        let secondURL = rootDirectory.appendingPathComponent("second.lock", isDirectory: false)
        // 先取得第一把锁。
        let firstLock = try ApplicationInstanceLock(lockFileURL: firstURL)
        // 再取得不同路径的第二把锁。
        let secondLock = try ApplicationInstanceLock(lockFileURL: secondURL)
        // 同时延长两个对象生命周期以真实覆盖并存状态。
        withExtendedLifetime((firstLock, secondLock)) {}
    }

    // 首实例释放描述符后，残留锁文件不能阻止下一次正常启动。
    @Test("释放后可以重新获取")
    func releasedLockCanBeReacquired() throws {
        // 使用唯一目录隔离残留锁文件。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后删除锁文件及目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 两次获取都指向同一个文件。
        let lockFileURL = rootDirectory.appendingPathComponent("reusable.lock", isDirectory: false)
        // 可选引用允许显式触发 deinit 和 close。
        var firstLock: ApplicationInstanceLock? = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 首次获取必须真实产生对象。
        #expect(firstLock != nil)
        // 清空唯一强引用，立即释放 flock。
        firstLock = nil
        // 同一路径现在应能再次成功获取。
        let secondLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 保持重获对象到断言路径结束。
        withExtendedLifetime(secondLock) {}
    }

    // 新建和既有锁文件都必须收紧为当前用户可读写。
    @Test("锁文件是普通文件且权限为 0600")
    func lockFileHasPrivatePermissions() throws {
        // 使用唯一目录读取确定的文件属性。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后删除本次锁文件。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 固定文件地址供属性查询。
        let lockFileURL = rootDirectory.appendingPathComponent("permissions.lock", isDirectory: false)
        // 先模拟旧版本留下的过宽锁文件权限。
        try Data().write(to: lockFileURL)
        // 显式放宽为组和其他用户可读写，确保测试覆盖收紧路径。
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lockFileURL.path)
        // 获取锁必须对既有文件执行 fchmod 收紧权限。
        let lock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 从同一路径读取内核返回的文件属性。
        let attributes = try FileManager.default.attributesOfItem(atPath: lockFileURL.path)
        // 锁载体必须是普通文件而非目录或特殊节点。
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        // POSIX 权限只允许当前用户读写。
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // 属性核对期间保持锁仍被持有。
        withExtendedLifetime(lock) {}
    }

    // 锁路径本身是目录时必须作为 IO 故障关闭式失败。
    @Test("锁文件 IO 错误不会退化为已运行")
    func invalidLockFileFailsClosed() throws {
        // 唯一临时目录同时作为非法锁文件节点。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后清理该目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        do {
            // O_RDWR 打开目录必须失败且不得继续尝试 flock。
            let lock = try ApplicationInstanceLock(lockFileURL: rootDirectory)
            // 防止意外成功对象提前释放掩盖错误。
            withExtendedLifetime(lock) {}
            // 任何成功都说明非普通节点绕过了保护。
            Issue.record("目录被错误地用作锁文件")
        } catch let ApplicationInstanceLockError.ioFailure(operation, code) {
            // 错误应来自打开或普通文件校验阶段。
            #expect(operation == "open" || operation == "validate")
            // 系统错误码必须保留为非零诊断信息。
            #expect(code != 0)
        } catch {
            // IO 故障不能伪装成已有实例占用。
            Issue.record("非法锁节点返回了错误类型：\(error)")
        }
    }

    // 创建唯一临时目录供单个测试安全读写。
    private func makeTemporaryDirectory() throws -> URL {
        // UUID 防止并行测试之间共享任何路径。
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLiteMac-InstanceLock-\(UUID().uuidString)", isDirectory: true)
        // 只创建本测试拥有的唯一目录。
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // 返回可安全交给锁实现的本地路径。
        return rootDirectory
    }
}
