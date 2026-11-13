import Foundation
import Testing
@testable import MacZillaCore

@Suite struct SiteManagerTests {
    static let xml = """
    <?xml version="1.0"?>
    <FileZilla3 version="3.71.1" platform="mac">
      <Servers>
        <Folder expanded="1">Praca
          <Server>
            <Host>ftp.example.com</Host><Port>21</Port><Protocol>0</Protocol><Type>1</Type>
            <User>jan</User><Pass encoding="base64">c2VrcmV0</Pass><Logontype>1</Logontype>
            <Name>Firma FTP</Name><RemoteDir>1 0 3 srv 4 www1</RemoteDir><Comments>test</Comments>
            <Bookmark><Name>zakładka</Name><RemoteDir>1 0 3 tmp</RemoteDir></Bookmark>
          </Server>
          <Folder expanded="0">Klienci
            <Server>
              <Host>sftp.example.com</Host><Port>2222</Port><Protocol>1</Protocol>
              <User>root</User><Logontype>5</Logontype><Keyfile>/Users/x/.ssh/id_ed25519</Keyfile>
              <Name>Prod</Name>
            </Server>
            <Server>
              <Host>bucket.s3.amazonaws.com</Host><Port>443</Port><Protocol>7</Protocol><Name>S3</Name>
            </Server>
          </Folder>
        </Folder>
        <Server>
          <Host>dav.example.com</Host><Port>443</Port><Protocol>5</Protocol><User>a</User>
          <Pass encoding="crypt" encryption="x">zzz</Pass><Logontype>1</Logontype><Name>Chmura</Name>
        </Server>
        <Server>
          <Host>anon.example.com</Host><Port>990</Port><Protocol>3</Protocol><Logontype>0</Logontype>
        </Server>
      </Servers>
    </FileZilla3>
    """

    @Test func importsFoldersProtocolsAndPasswords() throws {
        let r = try FileZillaImporter.parse(Data(Self.xml.utf8))
        #expect(r.sites.count == 4)
        #expect(r.skipped.count == 1 && r.skipped[0].contains("S3"))

        let ftp = try #require(r.sites.first { $0.site.name == "Firma FTP" })
        #expect(ftp.site.proto == .ftp && ftp.site.port == 21 && ftp.site.username == "jan")
        #expect(ftp.password == "sekret")
        #expect(ftp.site.folder == "Praca")
        #expect(ftp.site.startPath == "/srv/www1")
        #expect(ftp.site.notes == "test")
        #expect(r.opportunisticFTPCount == 1)

        let prod = try #require(r.sites.first { $0.site.name == "Prod" })
        #expect(prod.site.proto == .sftp && prod.site.port == 2222)
        #expect(prod.site.folder == "Praca/Klienci")
        #expect(prod.site.identityFile == "/Users/x/.ssh/id_ed25519")

        let dav = try #require(r.sites.first { $0.site.name == "Chmura" })
        #expect(dav.site.proto == .webdav && dav.site.host == "https://dav.example.com:443")
        #expect(dav.password == nil)
        #expect(dav.site.folder == nil)
        #expect(r.warnings.contains { $0.contains("hasłem głównym") })

        let anon = try #require(r.sites.first { $0.site.host == "anon.example.com" })
        #expect(anon.site.proto == .ftps && anon.site.username == "anonymous")
    }

    @Test func rejectsForeignXML() {
        #expect(throws: (any Error).self) { try FileZillaImporter.parse(Data("<a/>".utf8)) }
        #expect(throws: (any Error).self) { try FileZillaImporter.parse(Data("nie xml".utf8)) }
    }

    @Test func remoteDirParsing() {
        #expect(FileZillaImporter.parseRemoteDir("1 0 4 home 3 bob") == "/home/bob")
        #expect(FileZillaImporter.parseRemoteDir("1 0 9 my folder") == "/my folder")
        #expect(FileZillaImporter.parseRemoteDir("1 0") == "/")
        #expect(FileZillaImporter.parseRemoteDir("2 0 1 c") == nil)
        #expect(FileZillaImporter.parseRemoteDir("garbage") == nil)
    }

    @Test func treeGroupsAndFilters() {
        let a = SiteProfile(name: "Beta", proto: .sftp, host: "b.example.com", folder: "Praca/Klienci")
        let b = SiteProfile(name: "Alfa", proto: .ftp, host: "a.example.com", folder: "Praca")
        let c = SiteProfile(name: "Domowy", proto: .ftp, host: "home.lan")
        let tree = SiteTree.build([a, b, c])
        #expect(tree.map(\.name) == ["Praca", "Domowy"])
        let praca = tree[0]
        #expect(praca.isFolder && praca.siteCount == 2)
        #expect(praca.children.map(\.name) == ["Klienci", "Alfa"])
        #expect(praca.children[0].children[0].site == a)
        #expect(SiteTree.folderPaths([a, b, c]) == ["Praca", "Praca/Klienci"])

        let filtered = SiteTree.build([a, b, c], query: "home")
        #expect(filtered.map(\.name) == ["Domowy"])
        #expect(SiteTree.build([a, b, c], query: "klienci").first?.siteCount == 1)
    }

    @Test func quickConnectParsing() throws {
        let u = try #require(QuickConnect.parse("sftp://me:p%40ss@host.com:2200/var/www"))
        #expect(u.site.proto == .sftp && u.site.port == 2200 && u.site.username == "me")
        #expect(u.password == "p@ss" && u.site.startPath == "/var/www")

        let f = try #require(QuickConnect.parse("ftps://h.com"))
        #expect(f.site.proto == .ftps && f.site.port == 990)

        let d = try #require(QuickConnect.parse("https://dav.com/remote.php"))
        #expect(d.site.proto == .webdav && d.site.host == "https://dav.com/remote.php")

        let p = try #require(QuickConnect.parse("root@10.0.0.5:2022", defaultProtocol: .sftp))
        #expect(p.site.host == "10.0.0.5" && p.site.port == 2022 && p.site.username == "root")

        let h = try #require(QuickConnect.parse("example.org", defaultProtocol: .ftp))
        #expect(h.site.proto == .ftp && h.site.port == 21)

        #expect(QuickConnect.parse("") == nil)
        #expect(QuickConnect.parse("-oProxyCommand=x") == nil)
        #expect(QuickConnect.parse("gopher://x") == nil)
    }

    @Test func oldJSONWithoutNewFieldsStillLoads() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"X","proto":"FTP","host":"h","port":21,"username":"u","startPath":""}]
        """
        let sites = try JSONDecoder().decode([SiteProfile].self, from: Data(json.utf8))
        #expect(sites.count == 1 && sites[0].folder == nil)
    }
}
