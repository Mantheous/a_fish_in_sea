/// Where the "Open in Learning Suite" link-out should send the browser.
///
/// Feeds store Learning Suite's per-course iCal export link
/// (`https://learningsuite.byu.edu/iCalFeed/ical.php?courseID=…`), which is
/// a download, not a page: launching it silently saves a one-time `.ics`
/// snapshot instead of opening the class. Send the browser to the site
/// root instead — a signed-in Learning Suite session is redirected to the
/// student top page (`https://learningsuite.byu.edu/.<session>/student/top`).
/// The `.<session>` segment is minted per login, so it must never be
/// reconstructed from a stored URL.
const learningSuiteHomeUrl = 'https://learningsuite.byu.edu/';

/// Browser target for a class feed's link-out.
Uri learningSuiteHomeUri() => Uri.parse(learningSuiteHomeUrl);
