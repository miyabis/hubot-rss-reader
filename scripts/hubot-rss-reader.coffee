# Description:
#   Hubot RSS Reader
#
# Commands:
#   hubot rss add https://github.com/shokai.atom
#   hubot rss delete http://shokai.org/blog/feed
#   hubot rss delete #room_name
#   hubot rss list
#   hubot rss dump
#
# Author:
#   @shokai

'use strict'

path       = require 'path'
_          = require 'lodash'
debug      = require('debug')('hubot-rss-reader')
Promise    = require 'bluebird'
RSSChecker = require path.join __dirname, '../libs/rss-checker'
FindRSS    = Promise.promisify require 'find-rss'
nodeUrl    = require 'url'

## config
package_json = require path.join __dirname, '../package.json'
process.env.HUBOT_RSS_INTERVAL     ||= 60*10  # 10 minutes
process.env.HUBOT_RSS_HEADER       ||= ':sushi:'
process.env.HUBOT_RSS_USERAGENT    ||= "hubot-rss-reader/#{package_json.version}"
process.env.HUBOT_RSS_PRINTSUMMARY ||= "true"
process.env.HUBOT_RSS_PRINTIMAGE   ||= "true"
process.env.HUBOT_RSS_PRINTERROR   ||= "true"
process.env.HUBOT_RSS_IRCCOLORS    ||= "false"
process.env.HUBOT_RSS_LIMIT_ON_ADD ||= 5
process.env.HUBOT_RSS_ATTACHMENT_COLOR ||= "#3AA3E3"
process.env.HUBOT_RSS_PRINTFIELDS      ||= "false"

module.exports = (robot) ->

  logger =
    info: (msg) ->
      return debug msg if debug.enabled
      msg = JSON.stringify msg if typeof msg isnt 'string'
      robot.logger.info "#{debug.namespace}: #{msg}"
    error: (msg) ->
      return debug msg if debug.enabled
      msg = JSON.stringify msg if typeof msg isnt 'string'
      robot.logger.error "#{debug.namespace}: #{msg}"

  send_queue = []
  send = (envelope, entry) ->
    checker.getIcon entry.feed.sitelink
    .then (icons) ->
      entry.feed.favicon = icons["shortcuticon"]?[0] ? icons["icon"]?[0] ? icons["og:image"]?[0] ? null
      _send envelope, entry
    .catch (err) ->
      _send envelope, entry

  _send = (envelope, entry) ->
    envelope.changeUsername = entry.feed.title
    envelope.changeIcon = entry.feed.favicon

    unless envelope.changeIcon?
      url = nodeUrl.parse entry.feed.sitelink
      url = url.protocol + "//" + url.host + "/favicon.ico"
      envelope.changeIcon = url
    
    if entry.text?
      image_url = entry.summary.image_url
    else
      thumb_url = entry.summary.image_url

    update =
      title: "Update"
      value: entry.pubDate.toLocaleDateString() + " " + entry.pubDate.toLocaleTimeString()
      short: true

    if entry.category.length isnt 0
      category = 
        title: "Category"
        value: entry.category
        short: true

    if process.env.HUBOT_RSS_PRINTFIELDS is "true"
      fields = [update, category]

    data =
      attachments: [
          {
            fallback: entry.title
            color: process.env.HUBOT_RSS_ATTACHMENT_COLOR,
            title: entry.title,
            title_link: entry.url,
            text: entry.summary.text,
            thumb_url: thumb_url,
            image_url: image_url,
            ts: entry.pubDate / 1000 | 0,
            fields: fields
          }
        ]

    logger.info JSON.stringify data
    send_queue.push {envelope: envelope, body: data}

  getRoom = (msg) ->
    switch robot.adapterName
      when 'hipchat'
        msg.message.user.reply_to
      else
        msg.message.room

  setInterval ->
    return if typeof robot.send isnt 'function'
    return if send_queue.length < 1
    msg = send_queue.shift()
    try
      robot.adapter.url = robot.adapter.incomeUrl
      robot.send msg.envelope, msg.body
    catch err
      logger.error "Error on sending to room: \"#{room}\""
      logger.error err
  , 2000

  checker = new RSSChecker robot

  ## wait until connect redis
  robot.brain.once 'loaded', ->
    run = (opts) ->
      logger.info "checker start"
      checker.check opts
      .then ->
        logger.info "wait #{process.env.HUBOT_RSS_INTERVAL} seconds"
        robot.adapter.url = robot.adapter.incomeUrl
        setTimeout run, 1000 * process.env.HUBOT_RSS_INTERVAL
      , (err) ->
        logger.error err
        logger.info "wait #{process.env.HUBOT_RSS_INTERVAL} seconds"
        robot.adapter.url = robot.adapter.incomeUrl
        setTimeout run, 1000 * process.env.HUBOT_RSS_INTERVAL

    run()


  last_state_is_error = {}

  checker.on 'new entry', (entry) ->
    last_state_is_error[entry.feed.url] = false
    for room, feeds of checker.getAllFeeds()
      if room isnt entry.args.room and
         _.includes feeds, entry.feed.url
        logger.info "#{entry.title} #{entry.url} => #{room}"
        send {room: room}, entry

  checker.on 'error', (err) ->
    logger.error err
    if process.env.HUBOT_RSS_PRINTERROR isnt "true"
      return
    if last_state_is_error[err.feed.url]  # reduce error notify
      return
    last_state_is_error[err.feed.url] = true
    for room, feeds of checker.getAllFeeds()
      if _.includes feeds, err.feed.url
        summary =
          text: "[ERROR] #{err.feed.url} - #{err.error.message or err.error}"
        entry =
          feed: feed
          summary: summary
        send {room: room}, entry

  robot.respond /rss\s+(add|register)\s+(https?:\/\/[^\s]+)$/im, (msg) ->
    url = msg.match[2].trim() 
    last_state_is_error[url] = false
    logger.info "add #{url}"
    room = getRoom msg
    checker.addFeed(room, url)
    .then (res) ->
      new Promise (resolve) ->
        msg.send res
        resolve url
    .then (url) ->
      checker.fetch {url: url, room: room}
    .then (entries) ->
      entry_limit =
        if process.env.HUBOT_RSS_LIMIT_ON_ADD is 'false'
          entries.length
        else
          process.env.HUBOT_RSS_LIMIT_ON_ADD - 0
      for entry in entries.splice 0, entry_limit
        send {room: room}, entry
      if entries.length > 0
        msg.send "#{process.env.HUBOT_RSS_HEADER} #{entries.length} entries has been omitted"
    , (err) ->
      msg.send "[ERROR] #{err}"
      return if err.message isnt 'Not a feed'
      checker.deleteFeed(room, url)
      .then ->
        FindRSS url
      .then (feeds) ->
        return if feeds?.length < 1
        msg.send _.flatten([
          "found some Feeds from #{url}"
          feeds.map (i) -> " * #{i.url}"
        ]).join '\n'
    .catch (err) ->
      msg.send "[ERROR] #{err}"
      logger.error err.stack


  robot.respond /rss\s+(del|rm)\s+(https?:\/\/[^\s]+)$/im, (msg) ->
    url = msg.match[2].trim()
    logger.info "delete #{url}"
    checker.deleteFeed(getRoom(msg), url)
    .then (res) ->
      msg.send res
    .catch (err) ->
      msg.send err
      logger.error err.stack

  robot.respond /rss\s+(del|rm)\s+#([^\s]+)$/im, (msg) ->
    room = msg.match[2].trim()
    logger.info "delete ##{room}"
    checker.deleteRoom room
    .then (res) ->
      msg.send res
    .catch (err) ->
      msg.send err
      logger.error err.stack

  robot.respond /rss\s+list$/i, (msg) ->
    feeds = checker.getFeeds getRoom(msg)
    if feeds.length < 1
      msg.send "nothing"
    else
      msg.send feeds.join "\n"

  robot.respond /rss\s+dump$/i, (msg) ->
    feeds = checker.getAllFeeds()
    msg.send "JSON Dump\n" + JSON.stringify(feeds, null, 2)

  robot.respond /rss\s+help$/i, (msg) ->
    msg.send "**RSS Add**\n
    ```\n
    #{robot.name} rss add [url]\n
    #{robot.name} rss register [url]
    ```\n
    **RSS Delete**\n
    ```\n
    #{robot.name} rss del [url]\n
    #{robot.name} rss rm [url]
    ```\n
    **Room Delete**\n
    ```\n
    #{robot.name} rss del #[room]\n
    #{robot.name} rss rm #[room]
    ```\n
    **RSS List**\n
    ```\n
    #{robot.name} rss list
    ```\n
    **JSON dump (all list)**\n
    ```\n
    #{robot.name} rss dump
    ```\n
    **Help**\n
    ```\n
    #{robot.name} rss help
    ```\n"

