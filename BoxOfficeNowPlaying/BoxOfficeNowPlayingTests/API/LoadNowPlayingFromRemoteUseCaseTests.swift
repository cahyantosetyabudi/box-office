//
//  LoadNowPlayingFromRemoteUseCaseTests.swift
//  BoxOfficeNowPlayingTests
//
//  Created by Gordon Smith on 21/08/2020.
//  Copyright © 2020 Gordon Smith. All rights reserved.
//

import XCTest
import BoxOfficeNowPlaying

class RemoteNowPlayingLoader: NowPlayingLoader {

  public enum Error: Swift.Error {
    case connectivity
    case invalidResponse
  }

  public typealias Result = NowPlayingLoader.Result

  private let baseURL: URL
  private let client: LoadNowPlayingFromRemoteUseCaseTests.HTTPClientSpy

  init(baseURL: URL, client: LoadNowPlayingFromRemoteUseCaseTests.HTTPClientSpy) {
    self.baseURL = baseURL
    self.client = client
  }

  func execute(_ req: PagedNowPlayingRequest, completion: @escaping (Result) -> Void) {
    let request = URLRequest(url: enrich(baseURL, with: req))
    client.dispatch(request, completion: { result in
      switch result {
        case let .success((data, response)): completion(RemoteNowPlayingLoader.map(data, from: response))
        case .failure: completion(.failure(Error.connectivity))
      }
    })
  }
}

private extension RemoteNowPlayingLoader {
  func enrich(_ url: URL, with req: PagedNowPlayingRequest) -> URL {

    let requestURL = url
      .appendingPathComponent("3")
      .appendingPathComponent("movie")
      .appendingPathComponent("now_playing")

    var urlComponents = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
    urlComponents?.queryItems = [
      URLQueryItem(name: "language", value: req.language),
      URLQueryItem(name: "page", value: "\(req.page)")
    ]
    return urlComponents?.url ?? requestURL
  }

  static func map(_ data: Data, from response: HTTPURLResponse) -> Result {
    do {
      let items = try NowPlayingItemsMapper.map(data, from: response)
      return .success(items.asPageDTO)
    } catch {
      return .failure(error)
    }
  }
}

private extension RemoteNowPlayingFeed {
  var asPageDTO: NowPlayingFeed {
    return NowPlayingFeed(
      items: results.asCardDTO,
      page: number,
      totalPages: total_pages
    )
  }
}

private extension Array where Element == RemoteNowPlayingFeed.RemoteNowPlayingCard {
  var asCardDTO: [NowPlayingCard] {
    return map { item in NowPlayingCard(id: item.id, title: item.original_title, imagePath: item.poster_path) }
  }
}

final class NowPlayingItemsMapper {

  private static var OK_200: Int { return 200 }

  static func map(_ data: Data, from response: HTTPURLResponse) throws -> RemoteNowPlayingFeed {
    guard response.statusCode == OK_200, let page = try? JSONDecoder().decode(RemoteNowPlayingFeed.self, from: data) else {
      throw RemoteNowPlayingLoader.Error.invalidResponse
    }

    return page
  }
}

struct RemoteNowPlayingFeed: Decodable {

  struct RemoteNowPlayingCard: Decodable {
    let id: Int
    let original_title: String
    let poster_path: String
  }

  let results: [RemoteNowPlayingCard]
  let number: Int
  let total_pages: Int
}

extension HTTPURLResponse {
  private static var OK_200: Int { return 200 }

  var isOK: Bool {
    return statusCode == HTTPURLResponse.OK_200
  }
}

class LoadNowPlayingFromRemoteUseCaseTests: XCTestCase {

  func test_on_init_does_not_request_data_from_remote() {
    let (_, client) = makeSUT()
    XCTAssertTrue(client.requestedURLs.isEmpty)
  }

  func test_execute_requests_data_from_remote() {
    let request = PagedNowPlayingRequest(page: 1, language: "some-LANG")
    let expectedURL = makeURL("https://some-remote-svc.com/3/movie/now_playing?language=\(request.language)&page=\(request.page)")
    let baseURL = makeURL("https://some-remote-svc.com")
    let (sut, client) = makeSUT(baseURL: baseURL)
    sut.execute(request) { _ in }

    XCTAssertEqual(client.requestedURLs, [expectedURL])
  }

  func test_execute_requests_data_from_remote_on_each_call() {
    let request = PagedNowPlayingRequest(page: 1, language: "some-LANG")
    let expectedURL = makeURL("https://some-remote-svc.com/3/movie/now_playing?language=\(request.language)&page=\(request.page)")
    let baseURL = makeURL("https://some-remote-svc.com")
    let (sut, client) = makeSUT(baseURL: baseURL)

    sut.execute(request) { _ in }
    sut.execute(request) { _ in }

    XCTAssertEqual(client.requestedURLs, [expectedURL, expectedURL])
  }

  func test_execute_delivers_error_on_client_error() {
    let (sut, client) = makeSUT()
    let error = makeError()
    expect(sut, toCompleteWith: failure(.connectivity), when: {
      client.completes(with: .failure(error))
    })
  }

  func test_execute_delivers_error_on_non_success_response() {
    let (sut, client) = makeSUT()
    let samples = [299, 300, 399, 400, 418, 499, 500]
    let data = makeData()
    samples.indices.forEach { index in
      expect(sut, toCompleteWith: failure(.invalidResponse), when: {
        client.completes(withStatusCode: samples[index], data: data, at: index)
      })
    }
  }

  func test_execute_delivers_error_on_success_response_with_invalid_json() {
    let (sut, client) = makeSUT()
    let invalidJSONData = Data("invalid json".utf8)
    expect(sut, toCompleteWith: failure(.invalidResponse), when: {
      client.completes(withStatusCode: 200, data: invalidJSONData)
    })
  }

  func test_execute_delivers_empty_collection_on_success_response_with_no_items() {
    let (sut, client) = makeSUT()
    let emptyPage = makeNowPlayingFeed(items: [], pageNumber: 1, totalPages: 1)
    let emptyPageData = makeItemsJSONData(for: emptyPage.json)
    expect(sut, toCompleteWith: .success(emptyPage.model), when: {
      client.completes(withStatusCode: 200, data: emptyPageData)
    })
  }

  func test_execute_delivers_now_playing_feed_on_success_response_with_items() {
    let (sut, client) = makeSUT()
    let items = Array(0..<5).map { index in makeNowPlayingCard(id: index) }
    let page = makeNowPlayingFeed(items: items, pageNumber: 1, totalPages: 1)
    let pageData = makeItemsJSONData(for: page.json)
    expect(sut, toCompleteWith: .success(page.model), when: {
      client.completes(withStatusCode: 200, data: pageData)
    })
  }
}

extension LoadNowPlayingFromRemoteUseCaseTests {

  func makeSUT(baseURL: URL? = nil, file: StaticString = #file, line: UInt = #line) -> (NowPlayingLoader, HTTPClientSpy) {
    let client = HTTPClientSpy()
    let sut = RemoteNowPlayingLoader(baseURL: baseURL ?? makeURL(), client: client)

    checkForMemoryLeaks(client, file: file, line: line)
    checkForMemoryLeaks(sut, file: file, line: line)

    return (sut, client)
  }

  func expect(_ sut: NowPlayingLoader, toCompleteWith expectedResult: NowPlayingLoader.Result, when action: () -> Void, file: StaticString = #file, line: UInt = #line) {
    let exp = expectation(description: "Wait for load completion")
    let req = PagedNowPlayingRequest(page: 1)
    sut.execute(req, completion: { receivedResult in
      switch (receivedResult, expectedResult) {
        case let (.success(receivedItems), .success(expectedItems)):
          XCTAssertEqual(receivedItems, expectedItems, file: file, line: line)
        case let (.failure(receivedError as RemoteNowPlayingLoader.Error), .failure(expectedError as RemoteNowPlayingLoader.Error)):
          XCTAssertEqual(receivedError, expectedError, file: file, line: line)
        default:
          XCTFail("Expected result \(expectedResult) got \(receivedResult) instead", file: file, line: line)
      }
      exp.fulfill()
    })
    action()
    wait(for: [exp], timeout: 1.0)
  }

  func failure(_ error: RemoteNowPlayingLoader.Error) -> NowPlayingLoader.Result {
    return .failure(error)
  }

  private func makeItemsJSONData(for items: [String: Any]) -> Data {
    let data = try! JSONSerialization.data(withJSONObject: items)
    return data
  }

  func makeNowPlayingFeed(items: [(model: NowPlayingCard, json: [String : Any])] = [], pageNumber: Int = 0, totalPages: Int = 1) -> (model: NowPlayingFeed, json: [String: Any]) {

    let model = NowPlayingFeed(
      items: items.map { $0.model },
      page: pageNumber,
      totalPages: totalPages
    )

    let json: [String: Any] = [
      "results": items.map { $0.json },
      "number": pageNumber,
      "total_pages": totalPages
    ]

    return (model, json.compactMapValues { $0 })
  }

  func makeNowPlayingCard(id: Int, title: String? = nil, imagePath: String? = nil ) -> (model: NowPlayingCard, json: [String: Any]) {
    let model = NowPlayingCard(
      id: id,
      title: title ?? UUID().uuidString,
      imagePath: imagePath ?? "\(UUID().uuidString).jpg"
    )

    let json: [String: Any] = [
      "id": model.id,
      "original_title": model.title,
      "poster_path": model.imagePath
    ]

    return (model, json)
  }

  class HTTPClientSpy {

    var requestedURLs: [URL] {
      return messages.compactMap { $0.request.url }
    }

    private var messages: [(request: URLRequest, completion: (Result<(data: Data, resp: HTTPURLResponse), Error>) -> Void)] = []

    func dispatch(_ request: URLRequest, completion: @escaping (Result<(data: Data, resp: HTTPURLResponse), Error>) -> Void) {
      messages.append((request, completion))
    }

    func completes(with result: Result<(data: Data, resp: HTTPURLResponse), Error>, at index: Int = 0) {
      messages[index].completion(result)
    }

    func completes(withStatusCode code: Int, data: Data, at index: Int = 0) {
      let response = HTTPURLResponse(url: requestedURLs[index], statusCode: code, httpVersion: nil, headerFields: nil)!
      messages[index].completion(.success((data, response)))
    }

  }

}
