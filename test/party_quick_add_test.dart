import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/party_dashboard_repository.dart';
import 'package:ah_developer_kiryana_store/widgets/party_quick_add_menu.dart';

PartyRow c(String name, {String phone = '', int id = 1}) =>
    PartyRow(id: id, name: name, phone: phone, closing: 0, isCustomer: true);
PartyRow s(String name, {String phone = '', int id = 1}) =>
    PartyRow(id: id, name: name, phone: phone, closing: 0, isCustomer: false);

void main() {
  final all = [c('zaid', id: 1), s('Arfan Brothers', phone: '0300-111', id: 1), c('Ali', phone: '0333-999', id: 2), c('bilal', id: 3)];

  test('sirf chuni hui type, naam ke hisaab se (case-insensitive) sorted', () {
    expect([for (final r in pickerCandidates(all, forCustomer: true)) r.name], ['Ali', 'bilal', 'zaid']);
    expect([for (final r in pickerCandidates(all, forCustomer: false)) r.name], ['Arfan Brothers']);
  });

  test('search: naam (case-insensitive substring) ya phone', () {
    expect([for (final r in pickerCandidates(all, forCustomer: true, query: 'BIL')) r.name], ['bilal']);
    expect([for (final r in pickerCandidates(all, forCustomer: true, query: '0333')) r.name], ['Ali']);
    expect(pickerCandidates(all, forCustomer: true, query: 'zzz'), isEmpty);
  });

  test('khali / blank query => poori list; customer ka phone supplier list mein nahi aata', () {
    expect(pickerCandidates(all, forCustomer: true, query: '   ').length, 3);
    expect(pickerCandidates(all, forCustomer: false, query: '0333'), isEmpty);
  });
}
