enum PropertyType { villa, apartment, land }

class Property {
  final String id;
  final String ownerId;

  final String title;
  final PropertyType type;
  final String description;

  final String location;
  final double area; // m2
  final double price; // SAR

  final bool isAuction;
  final double? currentBid;

  final List<String> images; // assets paths

  final int views;
  final DateTime createdAt;

  Property({
    required this.id,
    required this.ownerId,
    required this.title,
    required this.type,
    required this.description,
    required this.location,
    required this.area,
    required this.price,
    required this.isAuction,
    this.currentBid,
    required this.images,
    required this.views,
    required this.createdAt,
  });
}
